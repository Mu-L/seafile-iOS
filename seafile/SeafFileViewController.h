//
//  SeafMasterViewController.h
//  seafile
//
//  Created by Wei Wang on 7/7/12.
//  Copyright (c) 2012 Seafile Ltd. All rights reserved.
//

#import <UIKit/UIKit.h>

typedef void(^DownloadCompleteBlock)(NSArray *array, NSString *errorStr);

@class SeafDetailViewController;
@class SeafLoadingView;

#import <CoreData/CoreData.h>

#import "SeafDir.h"
#import "SeafFile.h"


@interface SeafFileViewController : UITableViewController <SeafDentryDelegate, SeafFileUpdateDelegate> {
}

@property (strong, nonatomic) SeafConnection *connection;

@property (strong, nonatomic) SeafDir *directory;

@property (strong, readonly) SeafDetailViewController *detailViewController;

@property (strong, nonatomic) NSMutableDictionary *expandedSections; // To track expanded/collapsed sections

@property (strong, nonatomic) SeafLoadingView *loadingView;

- (void)refreshView;
- (void)uploadFile:(SeafUploadFile *)file;
- (void)deleteFile:(SeafFile *)file;
- (void)deleteFile:(SeafFile *)file completion:(void (^)(BOOL success, NSError *error))completion;
- (void)uploadFile:(SeafUploadFile *)ufile toDir:(SeafDir *)dir overwrite:(BOOL)overwrite;

- (void)photoSelectedChanged:(id<SeafPreView>)preViewItem to:(id<SeafPreView>)to;

- (BOOL)goTo:(NSString *)repo path:(NSString *)path;

- (void)pullToRefresh;

- (void)loadDataFromServerAndRefresh;

@end
