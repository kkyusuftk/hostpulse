// hostpulse-probe: a small sensor reader for macOS (Apple silicon and Intel).
//
// HostPulse copies this binary to ~/.cache/hostpulse/ on remote Macs and runs it
// over SSH. It only reads values: SMC keys, HID temperature sensors, CPU tick
// counters and the Wi-Fi link. It needs no root and changes nothing.
//
//   hostpulse-probe          summary as key=value lines
//   hostpulse-probe --all    summary plus every raw temperature/power reading

#import <CoreWLAN/CoreWLAN.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define PROBE_VERSION 1
#define MAX_CPUS 256
#define MAX_READINGS 512

static bool g_all = false;

#pragma mark - Output helpers

// Values must stay on one line and must not contain the '|' field separator.
static const char *clean(NSString *s) {
    NSString *t = [[s stringByReplacingOccurrencesOfString:@"|" withString:@"/"]
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    t = [t stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    return t.UTF8String ?: "";
}

#pragma mark - SMC (System Management Controller)

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

_Static_assert(sizeof(SMCParam) == 80, "SMCParam must match the AppleSMC user client layout");

enum { kSMCUserClientCall = 2, kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

static io_connect_t g_smc = 0;

static bool smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSMC"));
    if (!svc) return false;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_smc);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS;
}

static bool smc_call(SMCParam *in, SMCParam *out) {
    size_t size = sizeof(SMCParam);
    kern_return_t kr = IOConnectCallStructMethod(g_smc, kSMCUserClientCall, in, sizeof(SMCParam), out, &size);
    return kr == KERN_SUCCESS && out->result == 0;
}

static uint32_t fourcc(const char *s) {
    return (uint32_t)(uint8_t)s[0] << 24 | (uint32_t)(uint8_t)s[1] << 16 | (uint32_t)(uint8_t)s[2] << 8 | (uint8_t)s[3];
}

static void fourcc_str(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
}

static int hexdigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool smc_info(uint32_t key, SMCKeyInfo *info) {
    SMCParam in = {0}, out = {0};
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    if (!smc_call(&in, &out)) return false;
    *info = out.keyInfo;
    return true;
}

static bool smc_bytes(uint32_t key, const SMCKeyInfo *info, uint8_t bytes[32]) {
    SMCParam in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = kSMCReadKey;
    if (!smc_call(&in, &out)) return false;
    memcpy(bytes, out.bytes, 32);
    return true;
}

// Decodes the numeric SMC types we care about. "flt " is little-endian on Apple
// silicon; the fixed-point types (spXY / fpXY, Y = fraction bits) are big-endian.
static bool smc_decode(const SMCKeyInfo *info, const uint8_t *b, double *v) {
    char t[5];
    fourcc_str(info->dataType, t);
    uint32_t n = info->dataSize;
    if (!strcmp(t, "flt ") && n == 4) { float f; memcpy(&f, b, 4); *v = f; return isfinite(f); }
    if (!strcmp(t, "ui8 ") && n >= 1) { *v = b[0]; return true; }
    if (!strcmp(t, "ui16") && n == 2) { *v = (uint16_t)(b[0] << 8 | b[1]); return true; }
    if (!strcmp(t, "ui32") && n == 4) {
        *v = (double)((uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]);
        return true;
    }
    if (t[0] == 's' && t[1] == 'p' && n == 2 && hexdigit(t[3]) >= 0) {
        *v = (int16_t)(b[0] << 8 | b[1]) / (double)(1 << hexdigit(t[3]));
        return true;
    }
    if (t[0] == 'f' && t[1] == 'p' && n == 2 && hexdigit(t[3]) >= 0) {
        *v = (uint16_t)(b[0] << 8 | b[1]) / (double)(1 << hexdigit(t[3]));
        return true;
    }
    return false;
}

static bool smc_read(const char *key, double *v) {
    SMCKeyInfo info;
    uint8_t b[32];
    uint32_t k = fourcc(key);
    return g_smc && smc_info(k, &info) && smc_bytes(k, &info, b) && smc_decode(&info, b, v);
}

#pragma mark - Temperature readings

typedef enum { G_OTHER = 0, G_CPU, G_GPU, G_SSD, G_BATTERY, G_SOC } Group;

typedef struct {
    char name[48];
    double value;
    Group group;
    bool hid;
} Reading;

static Reading g_readings[MAX_READINGS];
static int g_nreadings = 0;

static void add_reading(const char *name, double v, Group g, bool hid) {
    if (g_nreadings >= MAX_READINGS || !(v > 15 && v < 130)) return;  // drop offsets, unplugged and bogus sensors
    Reading *r = &g_readings[g_nreadings++];
    strlcpy(r->name, name, sizeof r->name);
    r->value = v;
    r->group = g;
    r->hid = hid;
}

// SMC key prefixes. Apple silicon: Tp/Te = CPU clusters, Tg = GPU.
// Intel: TC = CPU, TG = GPU. Both: TH = SSD, TB = battery.
static Group smc_group(const char *k) {
#if defined(__arm64__)
    if (!strncmp(k, "Tp", 2) || !strncmp(k, "Te", 2)) return G_CPU;
    if (!strncmp(k, "Tg", 2)) return G_GPU;
#else
    if (!strncmp(k, "TC", 2)) return G_CPU;
    if (!strncmp(k, "TG", 2)) return G_GPU;
#endif
    if (!strncmp(k, "TH", 2)) return G_SSD;
    if (!strncmp(k, "TB", 2)) return G_BATTERY;
    return G_OTHER;
}

static void scan_smc(void) {
    double count = 0;
    if (!smc_read("#KEY", &count)) return;
    for (uint32_t i = 0; i < (uint32_t)count; i++) {
        SMCParam in = {0}, out = {0};
        in.data8 = kSMCGetKeyFromIndex;
        in.data32 = i;
        if (!smc_call(&in, &out)) continue;
        char name[5];
        fourcc_str(out.key, name);
        if (name[0] != 'T' && !(g_all && name[0] == 'P')) continue;
        SMCKeyInfo info;
        uint8_t b[32];
        double v;
        if (!smc_info(out.key, &info) || !smc_bytes(out.key, &info, b) || !smc_decode(&info, b, &v)) continue;
        if (name[0] == 'P') {  // power keys, only listed with --all
            if (v > 0.01 && v < 1000) printf("raw.power=%s|%.2f\n", name, v);
            continue;
        }
        add_reading(name, v, smc_group(name), false);
    }
}

typedef struct __HPHIDClient *HPHIDClientRef;
typedef struct __HPHIDService *HPHIDServiceRef;
typedef struct __HPHIDEvent *HPHIDEventRef;

// Apple silicon exposes named temperature sensors through the (private) HID
// event system. Resolved at runtime so the binary still loads anywhere.
static void scan_hid(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit) return;
    HPHIDClientRef (*create)(CFAllocatorRef) = (HPHIDClientRef(*)(CFAllocatorRef))dlsym(iokit, "IOHIDEventSystemClientCreate");
    int (*setMatching)(HPHIDClientRef, CFDictionaryRef) = (int (*)(HPHIDClientRef, CFDictionaryRef))dlsym(iokit, "IOHIDEventSystemClientSetMatching");
    CFArrayRef (*copyServices)(HPHIDClientRef) = (CFArrayRef(*)(HPHIDClientRef))dlsym(iokit, "IOHIDEventSystemClientCopyServices");
    HPHIDEventRef (*copyEvent)(HPHIDServiceRef, int64_t, int32_t, int64_t) =
        (HPHIDEventRef(*)(HPHIDServiceRef, int64_t, int32_t, int64_t))dlsym(iokit, "IOHIDServiceClientCopyEvent");
    CFTypeRef (*copyProperty)(HPHIDServiceRef, CFStringRef) = (CFTypeRef(*)(HPHIDServiceRef, CFStringRef))dlsym(iokit, "IOHIDServiceClientCopyProperty");
    double (*getFloat)(HPHIDEventRef, int32_t) = (double (*)(HPHIDEventRef, int32_t))dlsym(iokit, "IOHIDEventGetFloatValue");
    if (!create || !setMatching || !copyServices || !copyEvent || !copyProperty || !getFloat) return;

    HPHIDClientRef client = create(kCFAllocatorDefault);
    if (!client) return;
    NSDictionary *match = @{@"PrimaryUsagePage" : @0xff00, @"PrimaryUsage" : @5};  // Apple vendor page, temperature sensor
    setMatching(client, (__bridge CFDictionaryRef)match);
    CFArrayRef services = copyServices(client);
    if (services) {
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            HPHIDServiceRef svc = (HPHIDServiceRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef product = copyProperty(svc, CFSTR("Product"));
            HPHIDEventRef ev = copyEvent(svc, 15 /* kIOHIDEventTypeTemperature */, 0, 0);
            if (ev && product && CFGetTypeID(product) == CFStringGetTypeID()) {
                NSString *name = (__bridge NSString *)product;
                double v = getFloat(ev, 15 << 16);
                Group g = G_OTHER;
                if ([name containsString:@"pACC"] || [name containsString:@"eACC"] || [name containsString:@"CPU"]) g = G_CPU;
                else if ([name containsString:@"GPU"]) g = G_GPU;
                else if ([name containsString:@"NAND"] || [name containsString:@"SSD"]) g = G_SSD;
                else if ([name.lowercaseString containsString:@"battery"]) g = G_BATTERY;
                else if ([name containsString:@"tdie"] || [name containsString:@"SOC"]) g = G_SOC;
                add_reading(clean(name), v, g, true);
            }
            if (ev) CFRelease(ev);
            if (product) CFRelease(product);
        }
        CFRelease(services);
    }
    CFRelease(client);
}

typedef struct {
    double sum, max;
    int n;
} Agg;

static Agg aggregate(Group g, int source /* 0 = SMC, 1 = HID, 2 = any */) {
    Agg a = {0, 0, 0};
    for (int i = 0; i < g_nreadings; i++) {
        Reading *r = &g_readings[i];
        if (r->group != g) continue;
        if (source != 2 && r->hid != (source == 1)) continue;
        a.sum += r->value;
        a.n++;
        if (r->value > a.max) a.max = r->value;
    }
    return a;
}

static void print_group(const char *label, Group g) {
    Agg a = aggregate(g, 0);       // prefer SMC
    if (a.n == 0) a = aggregate(g, 1);  // fall back to HID
    if (a.n == 0) return;
    printf("temp.%s=%.1f\n", label, a.sum / a.n);
    printf("temp.%s_max=%.1f\n", label, a.max);
}

static void temperatures(void) {
    if (smc_open()) scan_smc();
    scan_hid();

    print_group("cpu", G_CPU);
    if (aggregate(G_CPU, 2).n == 0) print_group("cpu", G_SOC);  // die sensors as a CPU stand-in
    print_group("gpu", G_GPU);
    Agg ssd = aggregate(G_SSD, 2);
    if (ssd.n) printf("temp.ssd=%.1f\n", ssd.max);
    Agg bat = aggregate(G_BATTERY, 2);
    if (bat.n) printf("temp.battery=%.1f\n", bat.max);

    double hottest = 0;
    const char *hottestName = NULL;
    for (int i = 0; i < g_nreadings; i++) {  // unknown keys are often limits, not live readings
        Group g = g_readings[i].group;
        if (g != G_CPU && g != G_GPU && g != G_SOC && g != G_SSD) continue;
        if (g_readings[i].value > hottest) { hottest = g_readings[i].value; hottestName = g_readings[i].name; }
    }
    if (hottestName) printf("temp.max=%.1f\ntemp.max_name=%s\n", hottest, hottestName);
    printf("temp.sensors=%d\n", g_nreadings);

    if (g_all) {
        static const char *groups[] = {"other", "cpu", "gpu", "ssd", "battery", "soc"};
        for (int i = 0; i < g_nreadings; i++) {
            Reading *r = &g_readings[i];
            printf("raw.temp=%s|%s|%.2f|%s\n", r->hid ? "hid" : "smc", r->name, r->value, groups[r->group]);
        }
    }
}

#pragma mark - Fans and power

static void fans_and_power(void) {
    if (!g_smc) return;
    double n = 0;
    if (smc_read("FNum", &n)) {
        for (int i = 0; i < (int)n && i < 8; i++) {
            char k[5];
            double actual = 0, lo = 0, hi = 0;
            snprintf(k, sizeof k, "F%dAc", i);
            if (!smc_read(k, &actual)) continue;
            snprintf(k, sizeof k, "F%dMn", i);
            smc_read(k, &lo);
            snprintf(k, sizeof k, "F%dMx", i);
            smc_read(k, &hi);
            printf("fan=%d|%.0f|%.0f|%.0f\n", i, actual, lo, hi);
        }
    }
    double watts = 0;
    if (smc_read("PSTR", &watts) && watts > 0.05 && watts < 2000) printf("power.system=%.2f\n", watts);
}

#pragma mark - CPU (per core)

typedef struct {
    uint32_t ticks[CPU_STATE_MAX];
} CoreTicks;

static int cpu_sample(CoreTicks *out) {
    natural_t ncpu = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t ninfo = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &ncpu, &info, &ninfo) != KERN_SUCCESS) return 0;
    int n = (int)MIN(ncpu, (natural_t)MAX_CPUS);
    for (int i = 0; i < n; i++)
        for (int s = 0; s < CPU_STATE_MAX; s++) out[i].ticks[s] = (uint32_t)info[CPU_STATE_MAX * i + s];
    vm_deallocate(mach_task_self(), (vm_address_t)info, ninfo * sizeof(integer_t));
    return n;
}

// "E" / "P" per logical CPU on Apple silicon, from the device tree.
static void core_kinds(int n) {
    char kinds[MAX_CPUS + 1];
    memset(kinds, '?', sizeof kinds);
    kinds[MIN(n, MAX_CPUS)] = 0;
    bool any = false;
    io_registry_entry_t cpus = IORegistryEntryFromPath(MACH_PORT_NULL, "IODeviceTree:/cpus");
    if (!cpus) return;
    io_iterator_t it;
    if (IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &it) == KERN_SUCCESS) {
        io_object_t c;
        while ((c = IOIteratorNext(it))) {
            CFTypeRef type = IORegistryEntryCreateCFProperty(c, CFSTR("cluster-type"), kCFAllocatorDefault, 0);
            CFTypeRef lid = IORegistryEntryCreateCFProperty(c, CFSTR("logical-cpu-id"), kCFAllocatorDefault, 0);
            long idx = -1;
            if (lid && CFGetTypeID(lid) == CFNumberGetTypeID()) CFNumberGetValue(lid, kCFNumberLongType, &idx);
            else if (lid && CFGetTypeID(lid) == CFDataGetTypeID() && CFDataGetLength(lid) >= 4) {
                uint32_t v;
                memcpy(&v, CFDataGetBytePtr(lid), 4);
                idx = v;
            }
            if (type && CFGetTypeID(type) == CFDataGetTypeID() && CFDataGetLength(type) >= 1 && idx >= 0 && idx < n) {
                kinds[idx] = (char)CFDataGetBytePtr(type)[0];
                any = true;
            }
            if (type) CFRelease(type);
            if (lid) CFRelease(lid);
            IOObjectRelease(c);
        }
        IOObjectRelease(it);
    }
    IOObjectRelease(cpus);
    if (any) printf("cpu.kinds=%s\n", kinds);
}

#pragma mark - Wi-Fi

static NSString *run(NSString *path, NSArray<NSString *> *args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return nil;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// macOS 14+ hides the SSID from CoreWLAN without Location access; ipconfig still has it on most versions.
static NSString *ssid_fallback(NSString *iface) {
    NSString *out = run(@"/usr/sbin/ipconfig", @[ @"getsummary", iface ]);
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([t hasPrefix:@"SSID : "]) {
            NSString *ssid = [t substringFromIndex:7];
            return [ssid isEqualToString:@"<redacted>"] ? nil : ssid;
        }
    }
    return nil;
}

static void wifi(void) {
    CWInterface *wi = [CWWiFiClient sharedWiFiClient].interface;
    if (!wi) return;
    printf("wifi.iface=%s\n", wi.interfaceName.UTF8String ?: "");
    printf("wifi.power=%d\n", wi.powerOn ? 1 : 0);
    NSInteger rssi = wi.rssiValue;
    if (!wi.powerOn || rssi == 0) return;  // off or not associated
    printf("wifi.rssi=%ld\n", (long)rssi);
    printf("wifi.noise=%ld\n", (long)wi.noiseMeasurement);
    printf("wifi.tx=%.0f\n", wi.transmitRate);
    CWChannel *ch = wi.wlanChannel;
    if (ch) {
        long band = (long)ch.channelBand;
        printf("wifi.channel=%ld\n", (long)ch.channelNumber);
        printf("wifi.band=%s\n", band == 1 ? "2.4" : band == 2 ? "5" : band == 3 ? "6" : "");
    }
    static const char *phy[] = {"", "802.11a", "802.11b", "802.11g", "Wi-Fi 4", "Wi-Fi 5", "Wi-Fi 6", "Wi-Fi 7"};
    long mode = (long)wi.activePHYMode;
    if (mode > 0 && mode < 8) printf("wifi.phy=%s\n", phy[mode]);
    NSString *ssid = wi.ssid;
    if (!ssid.length && wi.interfaceName) ssid = ssid_fallback(wi.interfaceName);
    if (ssid.length) printf("wifi.ssid=%s\n", clean(ssid));
}

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        double interval = 1.0;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--all")) g_all = true;
            else if (!strcmp(argv[i], "--interval") && i + 1 < argc) interval = atof(argv[++i]);
        }
        setvbuf(stdout, NULL, _IOFBF, 1 << 16);

        static CoreTicks t0[MAX_CPUS], t1[MAX_CPUS];
        int n0 = cpu_sample(t0);
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();

        printf("probe.version=%d\n", PROBE_VERSION);
        temperatures();
        fans_and_power();
        wifi();
        static const char *thermal[] = {"nominal", "fair", "serious", "critical"};
        NSProcessInfoThermalState ts = NSProcessInfo.processInfo.thermalState;
        if (ts <= NSProcessInfoThermalStateCritical) printf("thermal=%s\n", thermal[ts]);

        // Per-core usage over the sampling window (the sensor reads above run inside it).
        double left = interval - (CFAbsoluteTimeGetCurrent() - start);
        if (left > 0) usleep((useconds_t)(left * 1e6));
        int n1 = cpu_sample(t1);
        int n = MIN(n0, n1);
        if (n > 0) {
            printf("cpu.cores=");
            for (int i = 0; i < n; i++) {
                uint32_t busy = 0, total = 0;
                for (int s = 0; s < CPU_STATE_MAX; s++) {
                    uint32_t d = t1[i].ticks[s] - t0[i].ticks[s];
                    total += d;
                    if (s != CPU_STATE_IDLE) busy += d;
                }
                printf("%s%.1f", i ? "," : "", total ? 100.0 * busy / total : 0.0);
            }
            printf("\n");
            core_kinds(n);
        }
        if (g_smc) IOServiceClose(g_smc);
        fflush(stdout);
    }
    return 0;
}
