// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <notify.h>
#import "../Shared/LidService.h"
#import "LowPowerControl.h"

// Only fixed SleepDisabled and battery LowPowerMode keys are writable. No caller-supplied commands, paths or settings.
static BOOL fake;
static NSString *folder, *journal;
static NSDictionary *owned;
static BOOL active, leaseActive, blocked, allowBattery;
static NSTimeInterval deadline, emergencySleepAt;
static NSXPCConnection *owner;
static NSString *reason=@"Ready";
static BOOL externalPower(void) {
    if (fake) return ![[NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:@"power"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"battery"];
    CFTypeRef info=IOPSCopyPowerSourcesInfo(); if (!info) return NO;
    CFStringRef type=IOPSGetProvidingPowerSourceType(info);
    BOOL ac=type && CFEqual(type,CFSTR(kIOPSACPowerValue)); CFRelease(info); return ac;
}
static BOOL hot(void) {
    if (fake) return [[NSFileManager defaultManager] fileExistsAtPath:[folder stringByAppendingPathComponent:@"hot"]];
    return NSProcessInfo.processInfo.thermalState>=NSProcessInfoThermalStateSerious;
}
static NSString *pmset(NSArray *arguments) {
    NSTask *task=[NSTask new]; NSPipe *pipe=[NSPipe pipe];
    task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/pmset"]; task.arguments=arguments;
    task.standardOutput=pipe; task.standardError=NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return nil;
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+3;
    while (task.running && NSProcessInfo.processInfo.systemUptime<end) usleep(10000);
    if (task.running) { [task terminate]; return nil; }
    if (task.terminationStatus) return nil;
    return [[NSString alloc] initWithData:pipe.fileHandleForReading.readDataToEndOfFile encoding:NSUTF8StringEncoding];
}
static BOOL settingPresent, containerPresent;
static NSMutableDictionary *systemSettings(void) {
    CFPreferencesSynchronize(CFSTR("com.apple.PowerManagement"),kCFPreferencesAnyUser,kCFPreferencesCurrentHost);
    id value=CFBridgingRelease(CFPreferencesCopyValue(CFSTR("SystemPowerSettings"),CFSTR("com.apple.PowerManagement"),kCFPreferencesAnyUser,kCFPreferencesCurrentHost));
    containerPresent=[value isKindOfClass:NSDictionary.class];
    return containerPresent?[value mutableCopy]:[NSMutableDictionary dictionary];
}
static NSInteger sleepDisabled(void) {
    if (fake) {
        settingPresent=[[NSFileManager defaultManager] fileExistsAtPath:[folder stringByAppendingPathComponent:@"value"]];
        containerPresent=settingPresent;
        return [[NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:@"value"] encoding:NSUTF8StringEncoding error:nil] integerValue];
    }
    NSDictionary *settings=systemSettings();
    id value=settings[@"SleepDisabled"]; settingPresent=value!=nil;
    if (!value) return 0; // Apple's absent key means ordinary sleep is enabled.
    if (CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()) return -1;
    return [value boolValue]?1:0;
}
static BOOL restoreAbsentKey(void) {
    if (fake) { [[NSFileManager defaultManager] removeItemAtPath:[folder stringByAppendingPathComponent:@"value"] error:nil]; return YES; }
    NSMutableDictionary *latest=systemSettings();
    if ([latest[@"SleepDisabled"] boolValue]) return NO; // A new override appeared; do not overwrite it.
    [latest removeObjectForKey:@"SleepDisabled"];
    CFTypeRef value=latest.count || [owned[@"containerPresent"] boolValue]?(__bridge CFTypeRef)latest:NULL;
    CFPreferencesSetValue(CFSTR("SystemPowerSettings"),value,CFSTR("com.apple.PowerManagement"),kCFPreferencesAnyUser,kCFPreferencesCurrentHost);
    BOOL ok=CFPreferencesSynchronize(CFSTR("com.apple.PowerManagement"),kCFPreferencesAnyUser,kCFPreferencesCurrentHost);
    if (ok) notify_post("com.apple.system.powermanagement.prefschange");
    return ok;
}
static BOOL setSleepDisabled(NSInteger value) {
    if (fake) return [[NSString stringWithFormat:@"%ld",(long)value] writeToFile:[folder stringByAppendingPathComponent:@"value"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return pmset(@[@"-a",@"disablesleep",value?@"1":@"0"])!=nil && sleepDisabled()==value;
}
static BOOL save(void) {
    if (![owned writeToFile:journal atomically:YES]) return NO;
    chmod(journal.fileSystemRepresentation,0600);
    int fd=open(journal.fileSystemRepresentation,O_RDONLY);
    BOOL ok=fd>=0 && fsync(fd)==0; if (fd>=0) close(fd);
    int dir=open(folder.fileSystemRepresentation,O_RDONLY);
    ok=dir>=0 && fsync(dir)==0 && ok; if (dir>=0) close(dir); return ok;
}
static BOOL restoreSleep(void) {
    if (!owned) { active=NO; return YES; }
    NSInteger current=sleepDisabled(); if (current<0) return NO;
    // Compare-and-restore only our value. Other pmset keys and changed values are untouched.
    if (current==1) {
        NSMutableDictionary *restoring=[owned mutableCopy]; restoring[@"restoring"]=@YES; owned=restoring;
        if (!save() || !setSleepDisabled([owned[@"original"] integerValue])) return NO;
        current=[owned[@"original"] integerValue];
    }
    // Recover a crash between writing false and removing an originally absent key.
    if (current==0 && [owned[@"restoring"] boolValue] && ![owned[@"originalPresent"] boolValue] && !restoreAbsentKey()) return NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:journal] && ![[NSFileManager defaultManager] removeItemAtPath:journal error:nil]) return NO;
    owned=nil; active=NO; return YES;
}
static BOOL restore(void) {
    BOOL sleepOK=restoreSleep();
    BOOL lowPowerOK=restoreLowPowerControl();
    leaseActive=NO;
    return sleepOK && lowPowerOK;
}
static void stop(NSString *why) {
    reason=why; blocked=YES;
    if (!restore()) reason=[why stringByAppendingString:@"; power-setting restoration failed; retry recovery"];
}
static BOOL renew(BOOL allowed, BOOL closed, BOOL lowPower) {
    allowBattery=allowed;
    if (blocked) return NO;
    if (!externalPower() && (!allowed || hot())) {
        BOOL thermal=hot();
        stop(thermal?@"Battery thermal cutout":@"Battery operation disabled");
        if (thermal) emergencySleepAt=NSProcessInfo.processInfo.systemUptime+2;
        return NO;
    }
    if (!closed && !restoreSleep()) { stop(@"Could not restore sleep control"); return NO; }
    NSInteger current=closed?sleepDisabled():0;
    if (closed && current<0) { stop(@"Cannot read SleepDisabled; no setting changed"); return NO; }
    if (closed && active && current!=1) { stop(@"SleepDisabled changed externally; session restored"); return NO; }
    if (closed && !active && current==0) {
        owned=@{@"original":@0,@"written":@1,@"originalPresent":@(settingPresent),@"containerPresent":@(containerPresent)};
        if (!save() || !setSleepDisabled(1)) { stop(@"Could not enable closed-lid sleep control"); return NO; }
    }
    BOOL batteryLowPower=lowPower && !externalPower();
    if (!applyLowPowerControl(batteryLowPower)) { stop(@"macOS rejected Low Power Mode, its value changed externally, or restoration failed. Turn automatic Low Power Mode off and retry Restore."); return NO; }
    active=closed; leaseActive=YES; deadline=NSProcessInfo.processInfo.systemUptime+5;
    reason=closed?(current==1 && !owned?@"Existing SleepDisabled setting left unchanged":@"Closed-lid lease active"):(batteryLowPower?@"Low Power Mode lease active":@"Battery power lease active");
    return YES;
}
static void evaluate(void) {
    if (!leaseActive) return;
    if (!fake && owner) {
        uid_t consoleUID=0;
        CFStringRef user=SCDynamicStoreCopyConsoleUser(NULL,&consoleUID,NULL); if (user) CFRelease(user);
        if (consoleUID!=owner.effectiveUserIdentifier) { stop(@"Console user changed"); return; }
    }
    if (externalPower() && !applyLowPowerControl(NO)) { stop(@"Could not restore Low Power Mode on external power"); return; }
    if (!externalPower() && hot()) {
        stop(@"Battery thermal cutout");
        // Let the hardware guard restore panel/backlight first. If it hangs, prioritize cooling.
        emergencySleepAt=NSProcessInfo.processInfo.systemUptime+2;
    } else if (!externalPower() && !allowBattery) stop(@"External power disconnected; battery use disabled");
    else if (NSProcessInfo.processInfo.systemUptime>deadline) stop(@"Five-second privileged lease expired");
}
static void powerChanged(void *context) { evaluate(); }
@interface LidSession : NSObject <GuillotineLidService>
@property (nonatomic, weak) NSXPCConnection *connection;
@end
@implementation LidSession
- (void)renewWithBatteryAllowed:(BOOL)allowed reply:(void (^)(BOOL,NSString *))reply {
    dispatch_async(dispatch_get_main_queue(),^{
        if (owner!=self.connection) { reply(NO,@"Lease connection is no longer current"); return; }
        reply(renew(allowed,YES,NO),reason);
    });
}
- (void)renewWithBatteryAllowed:(BOOL)allowed closedLid:(BOOL)closed lowPowerMode:(BOOL)lowPower reply:(void (^)(BOOL,NSString *))reply {
    dispatch_async(dispatch_get_main_queue(),^{
        if (owner!=self.connection) { reply(NO,@"Lease connection is no longer current"); return; }
        reply(renew(allowed,closed,lowPower),reason);
    });
}
- (void)releaseWithReply:(void (^)(BOOL,NSString *))reply {
    dispatch_async(dispatch_get_main_queue(),^{
        if (owner!=self.connection) { reply(NO,@"Lease connection is no longer current"); return; }
        BOOL ok=restore(); blocked=YES; reason=ok?@"Closed-lid override restored":@"Sleep-setting restoration failed";
        reply(ok,reason);
    });
}
@end
@interface Listener : NSObject <NSXPCListenerDelegate>
@end
@implementation Listener
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    // Signing is enforced by the listener on incoming connections/messages, not PID lookup.
    __block BOOL accepted=NO;
    dispatch_block_t accept=^{
        uid_t consoleUID=0;
        CFStringRef user=SCDynamicStoreCopyConsoleUser(NULL,&consoleUID,NULL); if (user) CFRelease(user);
        if (owner || connection.effectiveUserIdentifier==0 || connection.effectiveUserIdentifier!=consoleUID) return;
        connection.exportedInterface=[NSXPCInterface interfaceWithProtocol:@protocol(GuillotineLidService)];
        LidSession *session=[LidSession new]; session.connection=connection;
        connection.exportedObject=session; owner=connection; blocked=NO;
        __weak NSXPCConnection *weakConnection=connection;
        connection.invalidationHandler=^{ dispatch_async(dispatch_get_main_queue(),^{
            if (owner!=weakConnection) return;
            stop(@"Hardware guard disconnected"); owner=nil;
        }); };
        connection.interruptionHandler=connection.invalidationHandler;
        [connection resume]; accepted=YES;
    };
    if (NSThread.isMainThread) accept(); else dispatch_sync(dispatch_get_main_queue(),accept);
    return accepted;
}
@end
int main(int argc, char **argv) { @autoreleasepool {
    NSArray *args=NSProcessInfo.processInfo.arguments;
    fake=[args containsObject:@"--test-helper"];
    if (!fake && geteuid()!=0) { fputs("Lid helper requires macOS service approval.\n",stderr); return 2; }
    folder=fake?args.lastObject:@"/Library/Application Support/Guillotine";
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    if (!fake) {
        struct stat state;
        if (lstat(folder.fileSystemRepresentation,&state) || !S_ISDIR(state.st_mode) || state.st_uid!=0 || (state.st_mode&0022)) {
            fputs("Unsafe recovery directory ownership or permissions.\n",stderr); return 5;
        }
    }
    journal=[folder stringByAppendingPathComponent:@"lid-session.plist"];
    owned=[NSDictionary dictionaryWithContentsOfFile:journal];
    configureLowPowerControl(folder,fake);
    if (!restore()) { fputs("Pending sleep-setting recovery failed.\n",stderr); return 3; }
    if (fake) {
        puts("READY"); fflush(stdout);
        fcntl(STDIN_FILENO,F_SETFL,O_NONBLOCK);
        dispatch_source_t input=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,STDIN_FILENO,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(input,^{
            char bytes[256]; ssize_t n=read(STDIN_FILENO,bytes,sizeof(bytes));
            if (!n) { restore(); exit(0); }
            if (n>0) {
                NSString *message=[[NSString alloc] initWithBytes:bytes length:n encoding:NSUTF8StringEncoding];
                BOOL result=[message containsString:@"end"]?restore():renew([message containsString:@"battery=1"],![message containsString:@"lid=0"],[message containsString:@"lowpower=1"]);
                printf("%s %s\n",result?"OK":"NO",reason.UTF8String); fflush(stdout);
            }
        }); dispatch_resume(input);
        CFBridgingRetain(input);
    } else {
        NSXPCListener *listener=[[NSXPCListener alloc] initWithMachServiceName:GUILLOTINE_LID_SERVICE];
        [listener setConnectionCodeSigningRequirement:GUILLOTINE_GUARD_REQUIREMENT];
        Listener *delegate=[Listener new]; listener.delegate=delegate;
        [listener resume]; CFBridgingRetain(listener); CFBridgingRetain(delegate);
        CFRunLoopSourceRef power=IOPSNotificationCreateRunLoopSource(powerChanged,NULL);
        if (!power) return 4;
        CFRunLoopAddSource(CFRunLoopGetMain(),power,kCFRunLoopCommonModes);
        [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){ evaluate(); }];
    }
    for (NSNumber *number in @[@(SIGTERM),@(SIGINT)]) {
        int sig=number.intValue; signal(sig,SIG_IGN);
        dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,sig,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(source,^{ restore(); exit(0); }); dispatch_resume(source); CFBridgingRetain(source);
    }
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){
        evaluate();
        if (emergencySleepAt && NSProcessInfo.processInfo.systemUptime>=emergencySleepAt) {
            emergencySleepAt=0;
            if (fake) [@"sleep" writeToFile:[folder stringByAppendingPathComponent:@"sleep-request"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            else { io_connect_t port=IOPMFindPowerManagement(MACH_PORT_NULL); IOPMSleepSystem(port); IOServiceClose(port); }
        }
    }];
    [[NSRunLoop mainRunLoop] run];
    return 0;
}}
