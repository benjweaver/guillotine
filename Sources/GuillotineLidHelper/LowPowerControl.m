// SPDX-License-Identifier: GPL-3.0-or-later
#import "LowPowerControl.h"
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <notify.h>
#import <uuid/uuid.h>

static NSString *folder, *journal, *hostDomain;
static BOOL fake, observing;
static NSDictionary *owned;
static NSMutableDictionary *profile(void) {
    if (fake) {
        NSDictionary *host=[NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"host-power-profile.plist"]];
        id value=host[@"Battery Power"];
        return [value isKindOfClass:NSDictionary.class]?[value mutableCopy]:[NSMutableDictionary dictionary];
    }
    if (!hostDomain) return nil;
    CFStringRef domain=(__bridge CFStringRef)hostDomain;
    CFPreferencesSynchronize(domain,kCFPreferencesAnyUser,kCFPreferencesCurrentHost);
    id value=CFBridgingRelease(CFPreferencesCopyValue(CFSTR("Battery Power"),domain,kCFPreferencesAnyUser,kCFPreferencesCurrentHost));
    if (value && ![value isKindOfClass:NSDictionary.class]) return nil;
    return value?[value mutableCopy]:[NSMutableDictionary dictionary];
}
static BOOL writeFakeProfile(NSDictionary *settings) {
    NSString *path=[folder stringByAppendingPathComponent:@"host-power-profile.plist"];
    NSMutableDictionary *host=[[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy] ?: [NSMutableDictionary dictionary];
    host[@"Battery Power"]=settings;
    return [host writeToFile:path atomically:YES];
}
static NSInteger mode(NSDictionary *settings) {
    if (!settings) return -1;
    id value=settings[@"LowPowerMode"];
    if (!value) return 0;
    if (![value isKindOfClass:NSNumber.class]) return -1;
    NSInteger number=[value integerValue];
    return number>=0 && number<=2 && [value doubleValue]==number?number:-1;
}
static BOOL save(void) {
    if (![owned writeToFile:journal atomically:YES]) return NO;
    chmod(journal.fileSystemRepresentation,0600);
    int fd=open(journal.fileSystemRepresentation,O_RDONLY);
    BOOL ok=fd>=0 && fsync(fd)==0; if (fd>=0) close(fd);
    int dir=open(folder.fileSystemRepresentation,O_RDONLY);
    ok=dir>=0 && fsync(dir)==0 && ok; if (dir>=0) close(dir);
    return ok;
}
static BOOL writeMode(NSInteger value) {
    if (fake) {
        NSMutableDictionary *settings=profile(); settings[@"LowPowerMode"]=@(value);
        return writeFakeProfile(settings);
    }
    NSTask *task=[NSTask new]; task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/pmset"];
    // powermode 2 restores an existing High Power Mode on models supporting it.
    task.arguments=@[@"-b",value==2?@"powermode":@"lowpowermode",[@[@"0",@"1",@"2"] objectAtIndex:(NSUInteger)value]];
    task.standardOutput=NSFileHandle.fileHandleWithNullDevice; task.standardError=NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return NO;
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+3;
    while (task.running && NSProcessInfo.processInfo.systemUptime<end) usleep(10000);
    if (task.running) { [task terminate]; return NO; }
    return task.terminationStatus==0 && mode(profile())==value;
}
static BOOL removeOriginallyAbsentKey(void) {
    NSMutableDictionary *settings=profile();
    if (mode(settings)!=0) return NO;
    [settings removeObjectForKey:@"LowPowerMode"];
    if (fake) return writeFakeProfile(settings);
    // Merge only our fixed key into the latest battery profile, preserving user changes.
    CFPreferencesSetValue(CFSTR("Battery Power"),(__bridge CFTypeRef)settings,(__bridge CFStringRef)hostDomain,kCFPreferencesAnyUser,kCFPreferencesCurrentHost);
    BOOL ok=CFPreferencesSynchronize((__bridge CFStringRef)hostDomain,kCFPreferencesAnyUser,kCFPreferencesCurrentHost);
    if (ok) notify_post("com.apple.system.powermanagement.prefschange");
    return ok;
}
void configureLowPowerControl(NSString *directory, BOOL testing) {
    folder=directory; fake=testing;
    // Match Apple's IOPMEnergyPrefs getHostPrefsPath: LowPowerMode is a
    // hardware-specific preference, unlike the global SleepDisabled setting.
    // https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMEnergyPrefs.c
    if (!fake) {
        uuid_t host; struct timespec timeout={1,0}; char identifier[37];
        if (gethostuuid(host,&timeout)==0) {
            uuid_unparse_upper(host,identifier);
            hostDomain=[@"com.apple.PowerManagement." stringByAppendingString:@(identifier)];
        }
    }
    journal=[folder stringByAppendingPathComponent:@"low-power-session.plist"];
    owned=[NSDictionary dictionaryWithContentsOfFile:journal];
}
BOOL restoreLowPowerControl(void) {
    observing=NO;
    if (owned && (![owned[@"original"] isKindOfClass:NSNumber.class] || [owned[@"original"] doubleValue]!=[owned[@"original"] integerValue] || [owned[@"original"] integerValue]<0 || [owned[@"original"] integerValue]>2 || ![owned[@"originalPresent"] isKindOfClass:NSNumber.class])) return NO;
    if (!owned) return YES;
    NSInteger current=mode(profile()); if (current<0) return NO;
    if (current==1) {
        NSMutableDictionary *restoring=[owned mutableCopy]; restoring[@"restoring"]=@YES; owned=restoring;
        if (!save() || !writeMode([owned[@"original"] integerValue])) return NO;
        current=[owned[@"original"] integerValue];
    }
    if (current==0 && [owned[@"restoring"] boolValue] && ![owned[@"originalPresent"] boolValue] && !removeOriginallyAbsentKey()) return NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:journal] && ![[NSFileManager defaultManager] removeItemAtPath:journal error:nil]) return NO;
    owned=nil; return YES;
}
BOOL applyLowPowerControl(BOOL enabled) {
    if (!enabled) return restoreLowPowerControl();
    NSMutableDictionary *settings=profile(); NSInteger current=mode(settings);
    if (current<0) return NO;
    // Respect a different value written during our lease; stop instead of fighting it.
    if (observing && current!=1) { restoreLowPowerControl(); return NO; }
    if (current==1) { observing=YES; return YES; } // Preexisting Low Power Mode stays untouched.
    owned=@{@"original":@(current),@"originalPresent":@(settings[@"LowPowerMode"]!=nil)};
    observing=save() && writeMode(1);
    return observing;
}
