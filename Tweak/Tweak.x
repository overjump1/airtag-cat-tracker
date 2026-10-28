// AirTagCat — locationd hook
//
// Injected into locationd by libhooker (Dopamine). Hooks CLDurianService to
// capture every connected AirTag device and exposes them via a UNIX socket at
// /tmp/airtagcat.sock.  The AirTagCat app reads the socket for the device list
// and writes "playSound" / "stopSound" JSON commands back through it.
//
// Protocol: newline-delimited JSON.
//   tweak → app:  {"type":"devices","devices":[{"id":"…","name":"…","peripheralId":"…"}]}
//   app → tweak:  {"type":"playSound","deviceId":"…","sequence":[4,1,0,0,5,2,0,0]}
//                 {"type":"stopSound","deviceId":"…"}

#include <substrate.h>
#include <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <pthread.h>
#include <unistd.h>

#define SOCKET_PATH "/tmp/airtagcat.sock"

// State captured from CLDurianService — all live inside locationd's process,
// so we just keep raw pointers; locationd owns and manages these singletons.
static id   g_service    = nil;
static id   g_client     = nil;
static NSMutableDictionary *g_devices = nil;  // key → CLDurianDevice
static NSMutableDictionary *g_info    = nil;  // key → {id, name, peripheralId}

static NSMutableArray *g_clients  = nil;   // connected socket fds (NSNumber)
static int             g_serverFd = -1;

// Forward declarations
static void broadcastDeviceList(void);
static void handleCommand(NSDictionary *cmd);
static void *serverThread(void *arg);
static void *clientThread(void *arg);

// ── CLDurianService hook ──────────────────────────────────────────────────────
// Every interaction locationd has with an AirTag goes through this method.
// Hooking it gives us the service singleton, a client context, and the device.

%hook CLDurianService

- (void)performTask:(id)task forClient:(id)client onDevice:(id)device {
    %orig;

    if (!g_devices) g_devices = [[NSMutableDictionary alloc] init];
    if (!g_info)    g_info    = [[NSMutableDictionary alloc] init];

    [g_service release];
    g_service = [self retain];
    [g_client release];
    g_client  = [client retain];

    // Build a stable string key for this device
    NSString *key = nil;
    for (NSString *sel in @[@"identifier", @"serialNumber", @"deviceIdentifier"]) {
        id v = [device valueForKey:sel];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { key = v; break; }
        if ([v isKindOfClass:[NSUUID class]])  { key = [(NSUUID *)v UUIDString]; break; }
    }
    if (!key) key = [NSString stringWithFormat:@"dev_%p", (void *)device];

    [g_devices[key] release];
    g_devices[key] = [device retain];

    // Extract the underlying CBPeripheral's UUID so the app can read RSSI
    NSString *peripheralId = @"";
    id peri = [device valueForKey:@"peripheral"] ?: [device valueForKey:@"cbPeripheral"];
    if (peri) {
        id uuid = [device valueForKey:@"identifier"] ?: [peri valueForKey:@"identifier"];
        if ([uuid isKindOfClass:[NSUUID class]]) peripheralId = [(NSUUID *)uuid UUIDString];
    }

    // Device display name
    NSString *name = nil;
    for (NSString *ns in @[@"name", @"displayName", @"localizedName"]) {
        id v = [device valueForKey:ns];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { name = v; break; }
    }

    g_info[key] = [@{@"id": key,
                     @"name": name ?: @"AirTag",
                     @"peripheralId": peripheralId} mutableCopy];

    broadcastDeviceList();
}

%end

// ── Broadcast helpers ─────────────────────────────────────────────────────────

static void broadcastDeviceList(void) {
    if (!g_info || g_info.count == 0) return;

    NSDictionary *msg  = @{@"type": @"devices", @"devices": [g_info allValues]};
    NSData       *json = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
    if (!json) return;

    NSMutableData *frame = [json mutableCopy];
    uint8_t nl = '\n';
    [frame appendBytes:&nl length:1];

    @synchronized(g_clients) {
        NSMutableArray *dead = [NSMutableArray array];
        for (NSNumber *n in g_clients) {
            if (write(n.intValue, frame.bytes, frame.length) < 0)
                [dead addObject:n];
        }
        [g_clients removeObjectsInArray:dead];
    }
    [frame release];
}

// ── Command handler ───────────────────────────────────────────────────────────

static void handleCommand(NSDictionary *cmd) {
    NSString *type = cmd[@"type"];
    if (!type || !g_service || !g_client) return;

    BOOL play = [type isEqualToString:@"playSound"];
    BOOL stop = [type isEqualToString:@"stopSound"];
    if (!play && !stop) return;

    NSString *devKey = cmd[@"deviceId"];
    id device = devKey ? g_devices[devKey] : [[g_devices allValues] firstObject];
    if (!device) return;

    Class taskCls = NSClassFromString(@"CLDurianTask");
    if (!taskCls) return;

    id task = nil;

    if (play) {
        NSArray *seq = cmd[@"sequence"] ?: @[@4,@1,@0,@0,@5,@2,@0,@0];
        NSMutableData *data = [NSMutableData dataWithCapacity:[seq count]];
        for (NSNumber *b in seq) { uint8_t byte = [b unsignedCharValue]; [data appendBytes:&byte length:1]; }

        SEL sel = NSSelectorFromString(@"startSoundSequenceTaskWithSequence:");
        if (![taskCls respondsToSelector:sel])
            sel = NSSelectorFromString(@"startSoundSequenceTaskWithEncodedSequence:");
        if ([taskCls respondsToSelector:sel])
            task = ((id(*)(id,SEL,id))objc_msgSend)(taskCls, sel, data);
        [data release];
    } else {
        for (NSString *name in @[@"stopSoundTask", @"stopSoundSequenceTask"]) {
            SEL sel = NSSelectorFromString(name);
            if ([taskCls respondsToSelector:sel]) {
                task = ((id(*)(id,SEL))objc_msgSend)(taskCls, sel);
                break;
            }
        }
    }

    if (!task) return;
    SEL perf = @selector(performTask:forClient:onDevice:);
    ((void(*)(id,SEL,id,id,id))objc_msgSend)(g_service, perf, task, g_client, device);
}

// ── UNIX socket server ────────────────────────────────────────────────────────

static void *clientThread(void *arg) {
    int cfd = (int)(intptr_t)arg;

    // Immediately send the current device list to the new client
    broadcastDeviceList();

    NSMutableData *buf = [[NSMutableData alloc] init];
    char tmp[4096];
    NSData *newline = [NSData dataWithBytes:"\n" length:1];

    while (1) {
        ssize_t n = read(cfd, tmp, sizeof(tmp));
        if (n <= 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];

        while (1) {
            NSRange r = [buf rangeOfData:newline options:0 range:NSMakeRange(0, [buf length])];
            if (r.location == NSNotFound) break;
            NSData *line = [buf subdataWithRange:NSMakeRange(0, r.location)];
            [buf replaceBytesInRange:NSMakeRange(0, r.location + 1) withBytes:NULL length:0];
            NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if (msg) dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(msg); });
        }
    }

    [buf release];
    close(cfd);
    @synchronized(g_clients) { [g_clients removeObject:@(cfd)]; }
    return NULL;
}

static void *serverThread(void *arg) {
    unlink(SOCKET_PATH);

    int sfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sfd < 0) return NULL;
    g_serverFd = sfd;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path));

    if (bind(sfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(sfd); return NULL; }
    chmod(SOCKET_PATH, 0777);
    listen(sfd, 8);

    while (1) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) continue;
        @synchronized(g_clients) { [g_clients addObject:@(cfd)]; }
        pthread_t t;
        pthread_create(&t, NULL, clientThread, (void *)(intptr_t)cfd);
        pthread_detach(t);
    }
    return NULL;
}

// ── Constructor — runs when locationd loads this dylib ────────────────────────

%ctor {
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"locationd"]) return;
    %init;
    g_clients = [[NSMutableArray alloc] init];
    pthread_t t;
    pthread_create(&t, NULL, serverThread, NULL);
    pthread_detach(t);
}
