// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
void configureLowPowerControl(NSString *directory, BOOL fake);
BOOL applyLowPowerControl(BOOL enabled);
BOOL restoreLowPowerControl(void);
