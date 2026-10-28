// AirTagCat — locationd hook (pure ObjC runtime, no Substrate/Logos needed)
//
// libhooker (Dopamine) loads this dylib into locationd via the .plist filter.
// We hook CLDurianService -performTask:forClient:onDevice: using the standard
// ObjC runtime (method_setImplementation), so no substrate.h is required.
//
// Socket protocol: newline-delimited JSON on /tmp/airtagcat.sock
//   tweak → app:  {"type":"devices","devices":[{"id":"…","name":"…","peripheralId":"…"}]}
//   app → tweak:  {"type":"playSound","deviceId":"…","sequence":[4,1,0,0,5,2,0,0]}
//                 {"type":"stopSound","deviceId":"…"}

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <pthread.h>
#import <unistd.h>

#define SOCKET_PATH "/tmp/airtagcat.sock"

static id   g_service = nil;
static id   g_client  = nil;
static NSMutableDictionary *g_devices = nil;
static NSMutableDictionary *g_info    = nil;
static NSMutableArray      *g_clients = nil;
static int                  g_serverFd = -1;

static void (*orig_performTask)(id, SEL, id, id, id) = NULL;

static void broadcastDeviceList(void);
static void handleCommand(NSDictionary *cmd);
static void *serverThread(void *arg);
static void *clientThread(void *arg);

// ── Hook ──────────────────────────────────────────────────────────────────────

static void hook_performTask(id self, SEL _cmd, id task, id client, id device) {
    if (orig_performTask) orig_performTask(self, _cmd, task, client, device);

    if (!g_devices) g_devices = [[NSMutableDictionary alloc] init];
    if (!g_info)    g_info    = [[NSMutableDictionary alloc] init];

    [g_service release]; g_service = [self retain];
    [g_client  release]; g_client  = [client retain];

    NSString *key = nil;
    for (NSString *s in @[@"identifier", @"serialNumber", @"deviceIdentifier"]) {
        id v = [device valueForKey:s];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { key = v; break; }
        if ([v isKindOfClass:[NSUUID class]])  { key = [(NSUUID *)v UUIDString]; break; }
    }
    if (!key) key = [NSString stringWithFormat:@"dev_%p", (void *)device];

    [g_devices[key] release];
    g_devices[key] = [device retain];

    NSString *peripheralId = @"";
    id peri = [device valueForKey:@"peripheral"] ?: [device valueForKey:@"cbPeripheral"];
    if (peri) {
        id uuid = [device valueForKey:@"identifier"] ?: [peri valueForKey:@"identifier"];
        if ([uuid isKindOfClass:[NSUUID class]]) peripheralId = [(NSUUID *)uuid UUIDString];
    }

    NSString *name = nil;
    for (NSString *s in @[@"name", @"displayName", @"localizedName"]) {
        id v = [device valueForKey:s];
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) { name = v; break; }
    }

    g_info[key] = [@{@"id": key, @"name": name ?: @"AirTag",
                     @"peripheralId": peripheralId} mutableCopy];
    broadcastDeviceList();
}

// ── Broadcast ─────────────────────────────────────────────────────────────────

static void broadcastDeviceList(void) {
    if (!g_info || g_info.count == 0) return;
    NSData *json = [NSJSONSerialization
        dataWithJSONObject:@{@"type": @"devices", @"devices": [g_info allValues]}
        options:0 error:nil];
    if (!json) return;
    NSMutableData *frame = [json mutableCopy];
    uint8_t nl = '\n';
    [frame appendBytes:&nl length:1];
    @synchronized(g_clients) {
        NSMutableArray *dead = [NSMutableArray array];
        for (NSNumber *n in g_clients)
            if (write(n.intValue, frame.bytes, frame.length) < 0) [dead addObject:n];
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

    id device = cmd[@"deviceId"] ? g_devices[cmd[@"deviceId"]]
                                 : [[g_devices allValues] firstObject];
    if (!device) return;

    Class taskCls = NSClassFromString(@"CLDurianTask");
    if (!taskCls) return;

    id task = nil;
    if (play) {
        NSArray *seq = cmd[@"sequence"] ?: @[@4,@1,@0,@0,@5,@2,@0,@0];
        NSMutableData *data = [NSMutableData dataWithCapacity:seq.count];
        for (NSNumber *b in seq) { uint8_t byte = b.unsignedCharValue; [data appendBytes:&byte length:1]; }
        for (NSString *selName in @[@"startSoundSequenceTaskWithSequence:",
                                    @"startSoundSequenceTaskWithEncodedSequence:"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([taskCls respondsToSelector:sel]) {
                task = ((id(*)(id,SEL,id))objc_msgSend)(taskCls, sel, data);
                break;
            }
        }
        [data release];
    } else {
        for (NSString *selName in @[@"stopSoundTask", @"stopSoundSequenceTask"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([taskCls respondsToSelector:sel]) {
                task = ((id(*)(id,SEL))objc_msgSend)(taskCls, sel);
                break;
            }
        }
    }
    if (!task) return;

    SEL perf = NSSelectorFromString(@"performTask:forClient:onDevice:");
    ((void(*)(id,SEL,id,id,id))objc_msgSend)(g_service, perf, task, g_client, device);
}

// ── UNIX socket server ────────────────────────────────────────────────────────

static void *clientThread(void *arg) {
    int cfd = (int)(intptr_t)arg;
    broadcastDeviceList();
    NSMutableData *buf = [[NSMutableData alloc] init];
    char tmp[4096];
    NSData *nl = [NSData dataWithBytes:"\n" length:1];
    while (1) {
        ssize_t n = read(cfd, tmp, sizeof(tmp));
        if (n <= 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        while (1) {
            NSRange r = [buf rangeOfData:nl options:0 range:NSMakeRange(0, buf.length)];
            if (r.location == NSNotFound) break;
            NSData *line = [buf subdataWithRange:NSMakeRange(0, r.location)];
            [buf replaceBytesInRange:NSMakeRange(0, r.location+1) withBytes:NULL length:0];
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

// ── Constructor — runs when libhooker loads this dylib into locationd ─────────

__attribute__((constructor))
static void init_hook(void) {
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"locationd"]) return;

    Class cls = NSClassFromString(@"CLDurianService");
    if (cls) {
        SEL sel = NSSelectorFromString(@"performTask:forClient:onDevice:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            orig_performTask = (void(*)(id,SEL,id,id,id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_performTask);
        }
    }

    g_clients = [[NSMutableArray alloc] init];
    pthread_t t;
    pthread_create(&t, NULL, serverThread, NULL);
    pthread_detach(t);
}
