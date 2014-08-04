/**
 * Name: CrashReporter
 * Type: iOS application
 * Desc: iOS app for viewing the details of a crash, determining the possible
 *       cause of said crash, and reporting this information to the developer(s)
 *       responsible.
 *
 * Author: Lance Fetters (aka. ashikase)
 * License: GPL v3 (See LICENSE file for details)
 */

#import "RootViewController.h"

#import "CrashLog.h"
#import "CrashLogGroup.h"
#import "VictimViewController.h"
#import "ManualScriptViewController.h"

#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <launch.h>
#include <vproc.h>
#include "paths.h"

// NOTE: The following defines, as well as the launch_* related code later on,
//       comes from Apple's launchd utility (which is licensed under the Apache
//       License, Version 2.0)
//       https://www.opensource.apple.com/source/launchd/launchd-842.90.1/
typedef enum {
    VPROC_GSK_ZERO,
    VPROC_GSK_LAST_EXIT_STATUS,
    VPROC_GSK_GLOBAL_ON_DEMAND,
    VPROC_GSK_MGR_UID,
    VPROC_GSK_MGR_PID,
    VPROC_GSK_IS_MANAGED,
    VPROC_GSK_MGR_NAME,
    VPROC_GSK_BASIC_KEEPALIVE,
    VPROC_GSK_START_INTERVAL,
    VPROC_GSK_IDLE_TIMEOUT,
    VPROC_GSK_EXIT_TIMEOUT,
    VPROC_GSK_ENVIRONMENT,
    VPROC_GSK_ALLJOBS,
    // ...
} vproc_gsk_t;

extern vproc_err_t vproc_swap_complex(vproc_t vp, vproc_gsk_t key, launch_data_t inval, launch_data_t *outval);

extern NSString * const kNotificationCrashLogsChanged;

static BOOL isSafeMode$ = NO;
static BOOL reportCrashIsDisabled$ = YES;

@implementation RootViewController {
    BOOL hasShownSafeModeMessage_;
    BOOL hasShownReportCrashMessage_;
}

#pragma mark - Creation & Destruction

- (id)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        self.title = @"CrashReporter";

        // Add button for accessing "manual script" view.
        UIBarButtonItem *buttonItem;
        buttonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCompose
            target:self action:@selector(editBlame)];
        self.navigationItem.leftBarButtonItem = buttonItem;
        [buttonItem release];

        // Add button for deleting all logs.
        buttonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
            target:self action:@selector(trashButtonTapped)];
        self.navigationItem.rightBarButtonItem = buttonItem;
        [buttonItem release];

        // Listen for changes to crash log files.
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:) name:kNotificationCrashLogsChanged object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

#pragma mark - View (Setup)

- (void)viewDidLoad {
    // Add a refresh control.
    if (IOS_GTE(6_0)) {
        UITableView *tableView = [self tableView];
        tableView.alwaysBounceVertical = YES;
        UIRefreshControl *refreshControl = [NSClassFromString(@"UIRefreshControl") new];
        [refreshControl addTarget:self action:@selector(refresh:) forControlEvents:UIControlEventValueChanged];
        [tableView addSubview:refreshControl];
        [refreshControl release];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [CrashLogGroup forgetGroups];
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    if (isSafeMode$) {
        if (!hasShownSafeModeMessage_) {
            NSString *title = NSLocalizedString(@"SAFE_MODE_TITLE", nil);
            NSString *message = NSLocalizedString(@"SAFE_MODE_MESSAGE", nil);
            NSString *okTitle = NSLocalizedString(@"OK", nil);
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:nil
                cancelButtonTitle:okTitle otherButtonTitles:nil];
            [alert show];
            [alert release];

            hasShownSafeModeMessage_ = YES;
        }
    }

    if (reportCrashIsDisabled$) {
        if (!hasShownReportCrashMessage_) {
            NSString *title = NSLocalizedString(@"REPORTCRASH_DISABLED_TITLE", nil);
            NSString *message = NSLocalizedString(@"REPORTCRASH_DISABLED_MESSAGE", nil);
            NSString *okTitle = NSLocalizedString(@"OK", nil);
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:nil
                cancelButtonTitle:okTitle otherButtonTitles:nil];
            [alert show];
            [alert release];

            hasShownReportCrashMessage_ = YES;
        }
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
    return interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown;
}

#pragma mark - Actions

- (void)editBlame {
    ManualScriptViewController *controller = [ManualScriptViewController new];
    [self.navigationController pushViewController:controller animated:YES];
    [controller release];
}

- (void)trashButtonTapped {
    NSString *message = NSLocalizedString(@"DELETE_ALL_MESSAGE", nil);
    NSString *deleteTitle = NSLocalizedString(@"DELETE", nil);
    NSString *cancelTitle = NSLocalizedString(@"CANCEL", nil);
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:nil message:message delegate:self
        cancelButtonTitle:cancelTitle otherButtonTitles:deleteTitle, nil];
    [alert show];
    [alert release];
}

- (void)refresh:(id)sender {
    [CrashLogGroup forgetGroups];
    [self.tableView reloadData];

    if ([sender isKindOfClass:NSClassFromString(@"UIRefreshControl")]) {
        [sender endRefreshing];
    }
}

#pragma mark - Delegate (UIAlertView)

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == 1) {
        BOOL deleted = YES;

        // Delete all root crash logs.
        // NOTE: Must copy the array of groups as calling 'delete' on a group
        //       will modify the global storage (fast-enumeration does not allow
        //       such modifications).
        NSArray *groups = [[CrashLogGroup groupsForRoot] copy];
        for (CrashLogGroup *group in groups) {
            if (![group delete]) {
                deleted = NO;
            }
        }
        [groups release];

        // Delete all mobile crash logs.
        groups = [[CrashLogGroup groupsForMobile] copy];
        for (CrashLogGroup *group in groups) {
            if (![group delete]) {
                deleted = NO;
            }
        }
        [groups release];

        if (!deleted) {
            NSString *title = NSLocalizedString(@"ERROR", nil);
            NSString *message = NSLocalizedString(@"DELETE_ALL_FAILED", nil);
            NSString *okMessage = NSLocalizedString(@"OK", nil);
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:nil
                cancelButtonTitle:okMessage otherButtonTitles:nil];
            [alert show];
            [alert release];
        }

        [self refresh:nil];
    }
}

#pragma mark - Delegate (UITableViewDataSource)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return (section == 0) ? @"mobile" : @"root";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *crashLogGroups = (section == 0) ?  [CrashLogGroup groupsForMobile] : [CrashLogGroup groupsForRoot];
    return [crashLogGroups count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"."];
    if (cell == nil) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"."] autorelease];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSArray *crashLogGroups = (indexPath.section == 0) ?  [CrashLogGroup groupsForMobile] : [CrashLogGroup groupsForRoot];
    CrashLogGroup *group = [crashLogGroups objectAtIndex:indexPath.row];
    cell.textLabel.text = group.name;

    NSArray *crashLogs = [group crashLogs];
    unsigned long totalCount = [crashLogs count];
    unsigned long unviewedCount = 0;
    for (CrashLog *crashLog in crashLogs) {
        if (![crashLog isViewed]) {
            ++unviewedCount;
        }
    }

    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu/%lu", unviewedCount, totalCount];

    return cell;
}

#pragma mark - Delegate (UITableViewDelegate)

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *crashLogGroups = (indexPath.section == 0) ?  [CrashLogGroup groupsForMobile] : [CrashLogGroup groupsForRoot];
    CrashLogGroup *group = [crashLogGroups objectAtIndex:indexPath.row];

    VictimViewController *controller = [[VictimViewController alloc] initWithGroup:group];
    [self.navigationController pushViewController:controller animated:YES];
    [controller release];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath*)indexPath {
    NSArray *crashLogGroups = (indexPath.section == 0) ?  [CrashLogGroup groupsForMobile] : [CrashLogGroup groupsForRoot];
    CrashLogGroup *group = [crashLogGroups objectAtIndex:indexPath.row];
    if ([group delete]) {
        [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationLeft];
    } else {
        NSLog(@"ERROR: Failed to delete logs for group \"%@\".", [group name]);
    }
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    // Change background color of header to improve visibility.
    [view setTintColor:[UIColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0]];
}

@end

//==============================================================================

static void checkForDaemon(launch_data_t j, const char *key, void *context) {
    launch_data_t lo = launch_data_dict_lookup(j, LAUNCH_JOBKEY_LABEL);
    if (lo != NULL) {
        const char *label = launch_data_get_string(lo);
        if (strcmp(label, "com.apple.ReportCrash") == 0) {
            reportCrashIsDisabled$ = NO;
        }
    }
}

__attribute__((constructor)) static void init() {
    // Check if we were started in CrashReporter's Safe Mode.
    struct stat buf;
    BOOL failedToShutdown = (stat(kIsRunningFilepath, &buf) == 0);
    if (failedToShutdown) {
        // Mark that we are in Safe Mode.
        // NOTE: Safe Mode itself will have been enabled by the launch script.
        isSafeMode$ = YES;
    } else {
        // Create the "is running" file.
        FILE *f = fopen(kIsRunningFilepath, "w");
        if (f != NULL) {
            fclose(f);
        } else {
            fprintf(stderr, "ERROR: Failed to create \"is running\" file, errno = %d.\n", errno);
        }
    }

    // Check if ReportCrash daemon has been disabled.
    launch_data_t resp = NULL;
    if (vproc_swap_complex(NULL, VPROC_GSK_ALLJOBS, NULL, &resp) == NULL) {
        launch_data_dict_iterate(resp, checkForDaemon, NULL);
        launch_data_free(resp);
    }
}

/* vim: set ft=objc ff=unix sw=4 ts=4 tw=80 expandtab: */
