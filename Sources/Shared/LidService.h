// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#define GUILLOTINE_LID_SERVICE @"dev.guillotine.LidHelper"
#define GUILLOTINE_GUARD_REQUIREMENT @"anchor apple generic and identifier \"GuillotineGuard\" and certificate leaf[subject.OU] = \"AR25V66TVY\""
#define GUILLOTINE_HELPER_REQUIREMENT @"anchor apple generic and identifier \"GuillotineLidHelper\" and certificate leaf[subject.OU] = \"AR25V66TVY\""
@protocol GuillotineLidService
- (void)renewWithBatteryAllowed:(BOOL)allowed reply:(void (^)(BOOL, NSString *))reply;
- (void)renewWithBatteryAllowed:(BOOL)allowed closedLid:(BOOL)closed lowPowerMode:(BOOL)lowPower reply:(void (^)(BOOL, NSString *))reply;
- (void)releaseWithReply:(void (^)(BOOL, NSString *))reply;
@end
