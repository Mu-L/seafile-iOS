//
//  SeafDetailViewController.m
//  seafile
//
//  Created by Wei Wang on 7/7/12.
//  Copyright (c) 2012 Seafile Ltd. All rights reserved.
//

#import "MWPhotoBrowser.h"
#import "SVProgressHUD.h"

#import "SeafAppDelegate.h"
#import "SeafDetailViewController.h"
#import "FailToPreview.h"
#import "DownloadingProgressView.h"
#import "SeafTextEditorViewController.h"
#import "SeafUploadFile.h"
#import "SeafFileViewController.h"

#import "SeafPhoto.h"
#import "UIViewController+Extend.h"
#import "ExtentedString.h"
#import "Debug.h"
#import "SeafWechatHelper.h"
#import "SeafActionsManager.h"
#import <WebKit/WebKit.h>
#import <SafariServices/SafariServices.h>
#import "SeafDataTaskManager.h"

enum SHARE_STATUS {
    SHARE_BY_MAIL = 0,
    SHARE_BY_LINK = 1
};

#define PADDING                  10
#define ACTION_SHEET_OLD_ACTIONS 2000

#define SHARE_TITLE NSLocalizedString(@"How would you like to share this file?", @"Seafile")

@interface SeafDetailViewController ()<MFMailComposeViewControllerDelegate, MWPhotoBrowserDelegate, WKNavigationDelegate, SeafFileUpdateDelegate>
@property (strong, nonatomic) UIPopoverController *masterPopoverController;

@property (retain) FailToPreview *failedView;
@property (retain) DownloadingProgressView *progressView;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) MWPhotoBrowser *mwPhotoBrowser;
@property (nonatomic, strong) UITextView *textView;

@property BOOL performingLayout;
@property (retain) NSArray *photos;
@property NSUInteger currentPageIndex;

@property (strong) NSArray *barItemsStar;
@property (strong) NSArray *barItemsUnStar;
@property (strong) UIBarButtonItem *editItem;
@property (strong) UIBarButtonItem *exportItem;
@property (strong) UIBarButtonItem *deleteItem;
@property (strong) UIBarButtonItem *backItem;

@property (strong) UIDocumentInteractionController *docController;
@property (nonatomic, assign) BOOL previewDidEdited;
@property int shareStatus;

// New: Avoid presenting QLPreviewController multiple times
@property (nonatomic, assign) BOOL isPresentingQL;

@end


@implementation SeafDetailViewController

- (id)initWithCoder:(NSCoder *)decoder
{
    self = [super initWithCoder:decoder];
    self.previewDidEdited = NO;
    return self;
}
#pragma mark - Managing the detail item
// Check if preview was successful based on the current preview state.
- (BOOL)previewSuccess
{
    return (self.state == PREVIEW_WEBVIEW) || (self.state == PREVIEW_WEBVIEW_JS) || (self.state == PREVIEW_TEXT);
}

// Check if the current view controller is presented modally.
- (BOOL)isModal
{
    return self.presentingViewController != nil;
}

// Update navigation items depending on the current state and item properties.
- (void)updateNavigation
{
    if ([self isModal])
         [self.navigationItem setLeftBarButtonItem:self.backItem animated:NO];
    self.title = self.preViewItem.previewItemTitle;
    NSMutableArray *array = [[NSMutableArray alloc] init];
    if ([self.preViewItem isKindOfClass:[SeafFile class]]) {
        SeafFile *sfile = (SeafFile *)self.preViewItem;
        if ([sfile isStarred])
            [array addObjectsFromArray:self.barItemsStar];
        else
            [array addObjectsFromArray:self.barItemsUnStar];

        [self.exportItem setEnabled:([self.preViewItem exportURL] != nil)];
    }
    if ([self.preViewItem editable] && [self previewSuccess])
        [array addObject:self.editItem];
    self.navigationItem.rightBarButtonItems = array;
    
    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *barAppearance = [UINavigationBarAppearance new];
        barAppearance.backgroundColor = [UIColor whiteColor];
            barAppearance.shadowColor = [UIColor lightGrayColor]; // Add navigation bar bottom separator color
        
        self.navigationController.navigationBar.standardAppearance = barAppearance;
        self.navigationController.navigationBar.scrollEdgeAppearance = barAppearance;
    }
}

// Clear current preview settings and restore to initial state.
- (void)resetNavigation {
    self.navigationItem.title = nil;
    self.navigationItem.rightBarButtonItems = nil;
}

// Clear all views associated with the current preview.
- (void)clearPreView
{
    self.failedView.hidden = YES;
    self.progressView.hidden = YES;
    self.webView.hidden = YES;
    [self.textView removeFromSuperview];
    self.textView = nil;
    [self.webView evaluateJavaScript:@"document.body.innerHTML='';" completionHandler:nil];
    [self clearPhotosVIew];
}

// Update the preview state based on the current item's properties and state.
- (void)updatePreviewState
{
    if (self.state == PREVIEW_PHOTO && self.photos)
        return; // No change needed if already displaying photos

    _state = PREVIEW_NONE;
    if (!self.preViewItem) { // No item to preview

    } else if (self.preViewItem.previewItemURL) {
        _state = PREVIEW_QL_MODAL; // Default state
        if ([self.preViewItem.mime isEqualToString:@"image/svg+xml"] || [self.preViewItem.mime isEqualToString:@"application/sdoc"]) {
            _state = PREVIEW_WEBVIEW;
        } else if([self.preViewItem.mime isEqualToString:@"text/x-markdown"] || [self.preViewItem.mime isEqualToString:@"text/x-seafile"]) {
            _state = PREVIEW_WEBVIEW_JS;
        } else if ([self.preViewItem.mime containsString:@"text/"]) {
            _state = PREVIEW_TEXT;
        } else if (!IsIpad()) { // Use Quick Look for non-editable files on iPhone
            _state = self.preViewItem.editable ? PREVIEW_WEBVIEW : PREVIEW_QL_MODAL;
        } else if (![QLPreviewController canPreviewItem:self.preViewItem]) {
            _state = PREVIEW_FAILED; // Mark as failed if Quick Look can't preview the item
        }
    } else {
        _state = PREVIEW_DOWNLOADING; // Set state as downloading if no URL is available
    }
    if (_state != PREVIEW_QL_MODAL) { // Clear the preview if state is not Quick Look modal
        [self clearPreView];
    }
    Debug("preview %@ %@ state: %d", self.preViewItem.name, self.preViewItem.previewItemURL, _state);
}

- (void)refreshView
{
    [self updatePreviewState]; // Update the state based on the current item
    if (!self.isViewLoaded) return;

    [self updateNavigation]; // Update the navigation items
    CGFloat y = 64;
    if (@available(iOS 11.0, *)) {
       y = 44 + [UIApplication sharedApplication].keyWindow.safeAreaInsets.top;
    }
    CGRect r = CGRectMake(self.view.frame.origin.x, y, self.view.frame.size.width, self.view.frame.size.height - 64);
    switch (self.state) {
        case PREVIEW_DOWNLOADING:
            Debug (@"DownLoading file %@\n", self.preViewItem.previewItemTitle);
            self.progressView.frame = r;
            self.progressView.hidden = NO;
            [self.progressView configureViewWithItem:self.preViewItem progress:0]; // Initialize progress view
            break;
        case PREVIEW_FAILED:
            Debug ("Can not preview file %@ %@\n", self.preViewItem.previewItemTitle, self.preViewItem.previewItemURL);
            self.failedView.frame = r;
            self.failedView.hidden = NO;
            [self.failedView configureViewWithPrevireItem:self.preViewItem]; // Initialize failure view
            break;
        case PREVIEW_QL_MODAL: {
            Debug (@"Preview file %@ mime=%@ QL modal\n", self.preViewItem.previewItemTitle, self.preViewItem.mime);
            [self.qlViewController reloadData]; // Reload data for Quick Look view controller
            // If QLVC is already presented, do not present again
            if (!self.qlViewController.presentingViewController && !self.presentedViewController && !self.isPresentingQL) {
                if (self.isModal && self.isVisible) {
                    UIViewController *vc = self.presentingViewController;
                    // Mark to avoid repetition
                    self.isPresentingQL = YES;
                    [vc dismissViewControllerAnimated:NO completion:^{
                        [vc presentViewController:self.qlViewController animated:YES completion:^{
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self clearPreView];
                                self.isPresentingQL = NO;
                            });
                        }];
                    }];
                } else if (IsIpad()) {
                    // In iPad scenario
                    UIViewController *topVC = [SeafAppDelegate topViewController];
                    if (!topVC.presentedViewController && !self.isPresentingQL) {
                        self.isPresentingQL = YES;
                        [topVC.parentViewController presentViewController:self.qlViewController animated:YES completion:^{
                            [self clearPreView];
                            [self resetNavigation];
                            self.isPresentingQL = NO;
                        }];
                    }
                }
            }
            break;
        }
        case PREVIEW_WEBVIEW_JS:
        case PREVIEW_WEBVIEW: {
            Debug("Preview by webview %@\n", self.preViewItem.previewItemTitle);
            self.webView.navigationDelegate = self;
            self.webView.frame = r;
            if ([self.preViewItem isKindOfClass:[SeafFile class]]) {
                SeafFile *sFile = (SeafFile *)self.preViewItem;
                if ([sFile isSdocFile]) {
                    NSString *sdocURLString = [sFile getSdocWebViewURLString];

                    NSURLRequest *urlRequest = [sFile.connection buildRequest:sdocURLString method:@"GET" form:nil];
                    [self.webView loadRequest:urlRequest];
                } else {
                    [self.webView loadFileURL:self.preViewItem.previewItemURL allowingReadAccessToURL:self.preViewItem.previewItemURL];
                }
            } else {
                [self.webView loadFileURL:self.preViewItem.previewItemURL allowingReadAccessToURL:self.preViewItem.previewItemURL];
            }
            
            self.webView.hidden = NO;
            break;
        }
        case PREVIEW_TEXT:
            Debug("Preview text %@\n", self.preViewItem.previewItemTitle);
            [self.view addSubview:self.textView];
            self.textView.frame = r;
            self.textView.attributedText = [self attributedTextOfPreViewItem];
            self.textView.hidden = NO;
            [self.textView scrollsToTop]; // Scroll to top
            break;
        case PREVIEW_PHOTO:
            Debug("Preview photo %@\n", self.preViewItem.previewItemTitle);
            self.mwPhotoBrowser.view.frame = r;
            break;
        case PREVIEW_NONE:
            break;
        default:
            break;
    }
    if (@available(iOS 13.0, *)) {
        if ([self isPortrait]) {
            self.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModePrimaryHidden; // Adjust split view controller display mode for portrait
        } else {
            self.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeAllVisible; // Adjust split view controller display mode for landscape
        }
    }
}

// Set the preview item and refresh the view.
- (void)setPreViewItem:(id<SeafPreView>)item master:(UIViewController<SeafDentryDelegate> *)c
{
    if (self.masterPopoverController != nil)
        [self.masterPopoverController dismissPopoverAnimated:YES];
    if (item) Debug("preview %@", item.previewItemTitle);
    self.masterVc = c;
    self.photos = nil;
    self.preViewItem = item;
    //if need load from cache.
    [item load:(self.masterVc ? self.masterVc:self) force:NO];
    [self refreshView];
}

// Set and prepare photo views for preview.
- (void)setPreViewPhotos:(NSArray *)items current:(id<SeafPreView>)item master:(UIViewController<SeafDentryDelegate> *)c
{
    [self clearPreView];
    if (self.masterPopoverController != nil)
        [self.masterPopoverController dismissPopoverAnimated:YES];// Dismiss popover if exists
    self.masterVc = c;
    NSMutableArray *seafPhotos = [[NSMutableArray alloc] init];
    for (id<SeafPreView> file in items) {
        [file setDelegate:(self.masterVc ? self.masterVc:self)];
        [seafPhotos addObject:[[SeafPhoto alloc] initWithSeafPreviewIem: file]];
    }
    self.photos = seafPhotos;
    _state = PREVIEW_PHOTO;
    Debug("Preview photos PREVIEW_PHOTO: %d, %@ hasCache:%d", self.state, [item name], [item hasCache]);
    self.preViewItem = item;
    self.currentPageIndex = [items indexOfObject:item];
    _mwPhotoBrowser = nil;// force recreate mwPhotoBrowser
    [self.mwPhotoBrowser setCurrentPhotoIndex:self.currentPageIndex];
    [self.view addSubview:self.mwPhotoBrowser.view];
    self.mwPhotoBrowser.view.frame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height);
    [self.mwPhotoBrowser viewDidAppear:false];
    [self updateNavigation];
    [self.view setNeedsLayout];
}

// Handle the back button action.
- (void)goBack:(id)sender
{
    if (self.isModal)
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    else
        [self.navigationController popViewControllerAnimated:NO];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if([self respondsToSelector:@selector(edgesForExtendedLayout)])
        self.edgesForExtendedLayout = UIRectEdgeAll;
    // Do any additional setup after loading the view, typically from a nib.

    self.backItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Back", @"Seafile") style:UIBarButtonItemStylePlain target:self action:@selector(goBack:)];
    self.backItem.tintColor = BAR_COLOR_ORANGE;

    self.view.autoresizesSubviews = YES;
    self.view.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;

    self.editItem = [self getBarItem:@"editfile2" action:@selector(editFile:)size:18];
    self.exportItem = [self getBarItem:@"export2" action:@selector(export:)size:18];
    self.deleteItem = [self getBarItemAutoSize:@"delete" action:@selector(delete:)];

    UIBarButtonItem *starItem = [self getBarItem:@"star" action:@selector(unstarFile:)size:22];
    UIBarButtonItem *unstarItem = [self getBarItem:@"unstar" action:@selector(starFile:)size:22];
    UIBarButtonItem *space = [self getSpaceBarItem];
    self.barItemsStar  = [NSArray arrayWithObjects:self.exportItem, space, self.deleteItem, space, starItem, space, nil];
    self.barItemsUnStar  = [NSArray arrayWithObjects:self.exportItem, space, self.deleteItem, space, unstarItem, space, nil];

    if(IsIpad()) {
        NSArray *views = [[NSBundle mainBundle] loadNibNamed:@"FailToPreview_iPad" owner:self options:nil];
        self.failedView = [views objectAtIndex:0];
        views = [[NSBundle mainBundle] loadNibNamed:@"DownloadingProgress_iPad" owner:self options:nil];
        self.progressView = [views objectAtIndex:0];
    } else {
        NSArray *views = [[NSBundle mainBundle] loadNibNamed:@"FailToPreview_iPhone" owner:self options:nil];
        self.failedView = [views objectAtIndex:0];
        views = [[NSBundle mainBundle] loadNibNamed:@"DownloadingProgress_iPhone" owner:self options:nil];
        self.progressView = [views objectAtIndex:0];
    }
    self.webView = [[WKWebView alloc] initWithFrame:self.view.frame];
    self.webView.backgroundColor = [UIColor whiteColor];
    self.webView.autoresizesSubviews = YES;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.failedView];
    [self.view addSubview:self.progressView];
    [self.view addSubview:self.webView];

    [self.progressView.cancelBt addTarget:self action:@selector(cancelDownload:) forControlEvents:UIControlEventTouchUpInside];

    self.view.autoresizesSubviews = YES;
    self.view.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    self.navigationController.navigationBar.tintColor = BAR_COLOR_ORANGE;
    
    if (IsIpad() && self.navigationItem.leftBarButtonItem == nil && [self isPortrait]) {
        [self.navigationItem setLeftBarButtonItem:self.splitViewController.displayModeButtonItem animated:NO];
    }
    
    [self refreshView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateNavigation];
}

- (void)viewDidUnload
{
    [super viewDidUnload];
    self.preViewItem = nil;
    self.failedView = nil;
    self.progressView = nil;
    self.docController = nil;
    self.webView = nil;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

- (void)dealloc {
    [self.webView stopLoading];
    self.webView.navigationDelegate = nil;
    [self.webView removeFromSuperview];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGRect r = CGRectMake(self.view.frame.origin.x, 64, self.view.frame.size.width, self.view.frame.size.height - 64);// Calculate layout rectangle
    if (IsIpad()) {
        r = CGRectMake(self.view.frame.origin.x, 0, self.view.frame.size.width, self.view.frame.size.height - 0);
    }
    if (self.state == PREVIEW_PHOTO){
        if (IsIpad()) {
            self.mwPhotoBrowser.view.frame = r;// Adjust photo browser frame for iPad
        } else {
            UIDeviceOrientation orientation = (UIDeviceOrientation)[UIApplication sharedApplication].statusBarOrientation;// Get current device orientation
            if (orientation == UIDeviceOrientationPortrait || orientation == UIDeviceOrientationPortraitUpsideDown) {
                self.mwPhotoBrowser.view.frame = r;// Adjust photo browser frame for portrait orientation
            } else {
                self.mwPhotoBrowser.view.frame = CGRectMake(self.view.frame.origin.x, 32, self.view.frame.size.width, self.view.frame.size.height - 32);// Adjust photo browser frame for landscape orientation
            }
        }
    } else {
        if (self.view.subviews.count > 1) {
            UIView *v = [self.view.subviews objectAtIndex:0];
            v.frame = r; // Adjust frame for the first subview
        }
    }
    
    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *barAppearance = [UINavigationBarAppearance new];
        barAppearance.backgroundColor = [UIColor whiteColor];
        barAppearance.shadowColor = [UIColor lightGrayColor]; // Add navigation bar bottom separator color
        
        self.navigationController.navigationBar.standardAppearance = barAppearance;
        self.navigationController.navigationBar.scrollEdgeAppearance = barAppearance;
    }
}

#pragma mark - Split view

- (void)splitViewController:(UISplitViewController *)splitController willHideViewController:(UIViewController *)viewController withBarButtonItem:(UIBarButtonItem *)barButtonItem forPopoverController:(UIPopoverController *)popoverController
{
    [self.navigationItem setLeftBarButtonItem:barButtonItem animated:NO];// Set left bar button item when hiding the view controller
    self.masterPopoverController = popoverController;
}

- (void)splitViewController:(UISplitViewController *)splitController willShowViewController:(UIViewController *)viewController invalidatingBarButtonItem:(UIBarButtonItem *)barButtonItem
{
    // Called when the view is shown again in the split view, invalidating the button and popover controller.
    [self.navigationItem setLeftBarButtonItem:nil animated:NO];
    self.masterPopoverController = nil;
}

- (BOOL)splitViewController:(UISplitViewController *)svc shouldHideViewController:(UIViewController *)vc inOrientation:(UIInterfaceOrientation)orientation
{
    return !UIInterfaceOrientationIsLandscape(orientation); // Determine if the view controller should be hidden based on orientation
}

- (void)viewWillDisappear:(BOOL)animated
{
    if (self.masterPopoverController != nil) {
        [self.masterPopoverController dismissPopoverAnimated:YES];// Dismiss the master popover controller if it exists
    }
    [super viewWillDisappear:animated];
}

#pragma mark - SeafDentryDelegate
- (void)download:(SeafBase *)entry progress:(float)progress
{
    if (_preViewItem != entry) return; // Return if the entry is not the current preview item

    if (self.state == PREVIEW_PHOTO) {
        SeafPhoto *photo = [self getSeafPhoto:(id<SeafPreView>)entry];
        if (photo != nil)
            [photo setProgress:progress];// Update progress for the photo
        return;
    }
    if (self.state != PREVIEW_DOWNLOADING) {
        [self refreshView];// Refresh the view if state is not downloading
    } else
        [self.progressView configureViewWithItem:self.preViewItem progress:progress];// Update progress view
}

- (void)download:(SeafBase *)entry complete:(BOOL)updated
{
    if (self.state == PREVIEW_PHOTO) {
        SeafPhoto *photo = [self getSeafPhoto:(id<SeafPreView>)entry];
        if (photo == nil)
            return;// Return if no photo is found
        [photo complete:updated error:nil];
        [self updateNavigation];// Update navigation items
        return;
    }
    if (_preViewItem != entry) return;
    if (updated) {
        [self refreshView];
    }
}

- (void)showDownloadError:(NSString *)filename
{
    if (self.isVisible) {
        [SVProgressHUD showErrorWithStatus:[NSString stringWithFormat:NSLocalizedString(@"Failed to download file '%@'", @"Seafile"), self.preViewItem.previewItemTitle]];
    }
}

- (void)download:(SeafBase *)entry failed:(NSError *)error
{
    Debug("Failed to download %@ : %@ ", entry.name, error);
    if (self.state == PREVIEW_PHOTO) {
        SeafPhoto *photo = [self getSeafPhoto:(id<SeafPreView>)entry];
        if (photo == nil) return;// Return if no photo is found
        if (self.preViewItem == entry) {// Show download error
            [self showDownloadError:self.preViewItem.previewItemTitle];
        }
        NSError *error = [NSError errorWithDomain:[NSString stringWithFormat:@"Failed to download file '%@'",self.preViewItem.previewItemTitle] code:-1 userInfo:nil];
        [photo complete:false error:error];// Mark the photo as not complete with error
        return;
    }

    if (self.preViewItem != entry || self.preViewItem.hasCache)
        return;// Return if the entry is not the current item or if it is cached

    [self showDownloadError:self.preViewItem.previewItemTitle];
    [self setPreViewItem:nil master:nil];// Clear the preview item and master
}

#pragma mark - file operations
- (IBAction)delete:(id)sender {
    [self alertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete %@ ?", @"Seafile"), self.preViewItem.name] message:nil yes:^{
        if (_masterVc && [_masterVc isKindOfClass:[SeafFileViewController class]]) {
            [self goBack:nil];// Go back if deletion is confirmed
            [(SeafFileViewController *)_masterVc deleteFile:(SeafFile *)self.preViewItem];// Delete the file
        }
    } no:nil];
}

- (IBAction)starFile:(id)sender
{
    [(SeafFile *)self.preViewItem setStarred:YES withBlock:nil];
    [self updateNavigation];// Update navigation items
}

- (IBAction)unstarFile:(id)sender
{
    [(SeafFile *)self.preViewItem setStarred:NO withBlock:nil];
    [self updateNavigation];// Update navigation items
}

- (IBAction)editFile:(id)sender
{
    if (self.preViewItem.filesize > 10 * 1024 * 1024) {// Alert if file is too large to edit
        [self alertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"File '%@' is too large to edit", @"Seafile"), self.preViewItem.name]];
        return;
    }
    if (!self.preViewItem.strContent) { // Alert if file encoding is unidentified
        [self alertWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Failed to identify the coding of '%@'", @"Seafile"), self.preViewItem.name]];
        return;
    }
    SeafTextEditorViewController *editViewController = [[SeafTextEditorViewController alloc] initWithFile:self.preViewItem];
    editViewController.detailViewController = self;
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:editViewController];
    [navController setModalPresentationStyle:UIModalPresentationFullScreen];
    [self presentViewController:navController animated:YES completion:nil];
}

- (IBAction)cancelDownload:(id)sender
{
    id<SeafPreView> item = self.preViewItem;
    [self setPreViewItem:nil master:nil]; // Clear the preview item and master
//    [item cancelAnyLoading]; // Cancel any ongoing loading
    // TODO: Only cancel the current account, not all accounts
    for (SeafConnection *conn in SeafGlobal.sharedObject.conns) {
        if (conn.accountIdentifier) {
            SeafAccountTaskQueue *accountQueue = [SeafDataTaskManager.sharedObject accountQueueForConnection:conn];
            [accountQueue removeFileDownloadTask:item];
        }
    }
    if (!IsIpad())
        [self goBack:nil]; // Go back if not iPad
}

- (void)showAlertWithAction:(NSArray *)arr fromBarItem:(UIBarButtonItem *)item withTitle:(NSString *)title
{
    UIAlertController *alert = [self generateAlert:arr withTitle:title handler:^(UIAlertAction *action) {
        [self handleAction:action.title];
    }];
    alert.popoverPresentationController.barButtonItem = item;
    [self presentViewController:alert animated:true completion:nil];
}

- (IBAction)export:(id)sender
{
    if (![self.preViewItem isKindOfClass:[SeafFile class]]) return;// Return if the preview item is not a file
    SeafFile *file = (SeafFile *)self.preViewItem;
    NSArray *array = @[file.exportURL];
    [SeafActionsManager exportByActivityView:array item:self.exportItem targerVC:self];// Export the file using the activity view
}

- (IBAction)share:(id)sender
{
    if (![self.preViewItem isKindOfClass:[SeafFile class]]) return;// Return if the preview item is not a file
    [self.preViewItem setDelegate:self];
    NSString *email = NSLocalizedString(@"Email", @"Seafile");
    NSString *copy = NSLocalizedString(@"Copy Link to Clipboard", @"Seafile");
    NSMutableArray *titles = [NSMutableArray arrayWithObjects:email, copy, nil];
    if ([SeafWechatHelper wechatInstalled] && [self.preViewItem exportURL]) { // Add "Share to WeChat" option
        NSString *wechat = NSLocalizedString(@"Share to WeChat", @"Seafile");
        [titles addObject:wechat];
    }
//    [self showAlertWithAction:titles fromBarItem:self.deleteItem withTitle:SHARE_TITLE];
}

- (void)savedToPhotoAlbumWithError:(NSError *)error file:(SeafFile *)file
{
    if (error) {
        [SVProgressHUD showErrorWithStatus:[NSString stringWithFormat:NSLocalizedString(@"Failed to save %@ to album", @"Seafile"), file.name]];
    } else {
        [SVProgressHUD showSuccessWithStatus:[NSString stringWithFormat:NSLocalizedString(@"Succeeded to save %@ to album", @"Seafile"), file.name]];
    }
}

- (void)handleAction:(NSString *)title
{
    SeafFile *file = (SeafFile *)self.preViewItem;
    if ([NSLocalizedString(@"Email", @"Seafile") isEqualToString:title]
               || [NSLocalizedString(@"Copy Link to Clipboard", @"Seafile") isEqualToString:title]) {
        if (![self checkNetworkStatus])// Return if there is no network connection
            return;

        if ([NSLocalizedString(@"Email", @"Seafile") isEqualToString:title])// Set share status to "Share by Mail"
            _shareStatus = SHARE_BY_MAIL;
        else
            _shareStatus = SHARE_BY_LINK;// Set share status to "Share by Link"
        if (!file.shareLink) {// Show status for generating share link
            [SVProgressHUD showWithStatus:NSLocalizedString(@"Generate share link ...", @"Seafile")];
            [file generateShareLink:self];// Generate share link
        } else {
            [self generateSharelink:file WithResult:YES];// Handle generated share link
        }
    } else if ([NSLocalizedString(@"Share to WeChat", @"Seafile") isEqualToString:title]) {
        [SeafWechatHelper shareToWechatWithFile:file];// Share file to WeChat
    }
}

#pragma mark - SeafShareDelegate
- (void)generateSharelink:(SeafBase*)entry WithResult:(BOOL)success
{
    if (entry != self.preViewItem) {// Dismiss the progress HUD if the entry is not the current item
        [SVProgressHUD dismiss];
        return;
    }

    SeafFile *file = (SeafFile *)self.preViewItem;
    if (!success) {
        [SVProgressHUD showErrorWithStatus:[NSString stringWithFormat:NSLocalizedString(@"Failed to generate share link of file '%@'", @"Seafile"), file.name]];
        return;
    }
    [SVProgressHUD showSuccessWithStatus:NSLocalizedString(@"Generate share link success", @"Seafile")];
    Debug("file %@ sharelink;%@", file.name, file.shareLink);

    if (_shareStatus == SHARE_BY_MAIL) {
        [self sendMailInApp:file.name shareLink:file.shareLink];// Send mail with the share link
    } else if (_shareStatus == SHARE_BY_LINK){
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        [pasteboard setString:file.shareLink];// Set the share link in the pasteboard
    }
}

#pragma mark - sena mail inside app
- (void)sendMailInApp:(NSString *)name shareLink:(NSString *)shareLink
{
    Debug("send mail: %@", shareLink);
    Class mailClass = (NSClassFromString(@"MFMailComposeViewController"));// Get the mail compose view controller class
    if (!mailClass) {
        [self alertWithTitle:NSLocalizedString(@"This function is not supportted yet，you can copy it to the pasteboard and send mail by yourself", @"Seafile")];
        return;
    }
    if (![mailClass canSendMail]) {
        [self alertWithTitle:NSLocalizedString(@"The mail account has not been set yet", @"Seafile")];
        return;
    }
    SeafAppDelegate *appdelegate = (SeafAppDelegate *)[[UIApplication sharedApplication] delegate];
    MFMailComposeViewController *mailPicker = appdelegate.globalMailComposer;
    mailPicker.mailComposeDelegate = self;
    mailPicker.modalPresentationStyle = UIModalPresentationFullScreen;

    [mailPicker setSubject:[NSString stringWithFormat:NSLocalizedString(@"File '%@' is shared with you using %@", @"Seafile"), name, APP_NAME]];
    NSString *emailBody = [NSString stringWithFormat:NSLocalizedString(@"Hi,<br/><br/>Here is a link to <b>'%@'</b> in my %@:<br/><br/> <a href=\"%@\">%@</a>\n\n", @"Seafile"), name, APP_NAME, shareLink, shareLink];
    [mailPicker setMessageBody:emailBody isHTML:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self presentViewController:mailPicker animated:YES completion:nil];
    });
}
#pragma mark - MFMailComposeViewControllerDelegate
- (void)mailComposeController:(MFMailComposeViewController *)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError *)error
{
    NSString *msg;
    switch (result) {
        case MFMailComposeResultCancelled:
            msg = @"cancalled";
            break;
        case MFMailComposeResultSaved:
            msg = @"saved";
            break;
        case MFMailComposeResultSent:
            msg = @"sent";
            break;
        case MFMailComposeResultFailed:
            msg = @"failed";
            break;
        default:
            msg = @"";
            break;
    }
    [self dismissViewControllerAnimated:YES completion:^{
        SeafAppDelegate *appdelegate = (SeafAppDelegate *)[[UIApplication sharedApplication] delegate];
        [appdelegate cycleTheGlobalMailComposer];
    }];

    Debug("share file:send mail %@\n", msg);
}

# pragma - WKWebViewDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    SeafFile *sFile = (SeafFile *)self.preViewItem;
    if (![sFile isSdocFile]) {
        if (self.preViewItem) {
            NSString *js = [NSString stringWithFormat:@"setContent(\"%@\");", [self.preViewItem.strContent stringEscapedForJavasacript]];// Prepare JavaScript for setting content
            [self.webView evaluateJavaScript:js completionHandler:nil];// Evaluate JavaScript
        }
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    SeafFile *sFile = (SeafFile *)self.preViewItem;
    if ([sFile isSdocFile]) {
        NSURL *originalURL = navigationAction.request.URL;
        Debug(@"Request URL: %@", navigationAction.request.URL);
        if ([originalURL.absoluteString containsString:@"login/?next"] && ![originalURL.absoluteString containsString:@"mobile-login/?next"]) {
            // Cancel current loading first
            decisionHandler(WKNavigationActionPolicyCancel);
            
            NSString *sdocURLString = [sFile getSdocWebViewURLString];
            
            NSString *mobileLoginURLString = [NSString stringWithFormat:@"%@/mobile-login/?next=%@",
                                              sFile.connection.address,
                                              sdocURLString];
            NSURLRequest *urlRequest = [sFile.connection buildRequest:mobileLoginURLString method:@"GET" form:nil];
            
            [webView loadRequest:urlRequest];
            
            // Return here to avoid calling decisionHandler twice
            return;
        }
    }
    
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (UIBarButtonItem *)getSpaceBarItem {
    float spacewidth = IsIpad() ? 20.0f : 8.0f;
    UIBarButtonItem *space = [self getSpaceBarItem:spacewidth];
    return space;
}

#pragma -mark QLPreviewControllerDataSource
- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller
{
    if (self.state != PREVIEW_QL_MODAL)
        return 0;
    return 1;
}

- (id <QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index;
{
    if (!ios7 && index < 0) index = 0;
    if (index < 0 || index >= 1) {
        return nil;
    }
    return self.preViewItem;
}

#pragma -mark QLPreviewControllerDelegate

- (QLPreviewItemEditingMode)previewController:(QLPreviewController *)controller editingModeForPreviewItem:(id<QLPreviewItem>)previewItem  API_AVAILABLE(ios(13.0)){
    SeafFile *file = (SeafFile *)previewItem;
    if ([file.mime isEqualToString:@"application/pdf"]) {
        return QLPreviewItemEditingModeCreateCopy;// Allow creating a copy for PDF files
    } else {
        return QLPreviewItemEditingModeDisabled;// Disable editing for other files
    }
}

- (void)previewController:(QLPreviewController *)controller didUpdateContentsOfPreviewItem:(id<QLPreviewItem>)previewItem {
    Debug(@"previewItem did update :%@", previewItem);
}

- (void)previewController:(QLPreviewController *)controller didSaveEditedCopyOfPreviewItem:(id<QLPreviewItem>)previewItem atURL:(NSURL *)modifiedContentsURL {
    if (previewItem && modifiedContentsURL) {
        self.previewDidEdited = YES;
        SeafFile *file = (SeafFile *)previewItem;
        
        [file saveEditedPreviewFile:modifiedContentsURL];
    }
}

- (void)previewControllerDidDismiss:(QLPreviewController *)controller {
    if (self.previewDidEdited) {
        SeafFile *file = (SeafFile *)self.preViewItem;
        if (file && [file respondsToSelector:@selector(autoupload)]) {
            [file performSelector:@selector(autoupload)];
        }
        
        self.previewDidEdited = NO;
    }
    self.preViewItem = nil;
    self.qlViewController = nil;
}

- (MWPhotoBrowser *)mwPhotoBrowser
{
    if (!_mwPhotoBrowser) {
        _mwPhotoBrowser = [[MWPhotoBrowser alloc] initWithDelegate:self];
        _mwPhotoBrowser.displayActionButton = false;
        _mwPhotoBrowser.displayNavArrows = false;
        _mwPhotoBrowser.displaySelectionButtons = false;
        _mwPhotoBrowser.alwaysShowControls = false;
        _mwPhotoBrowser.zoomPhotosToFill = YES;
        _mwPhotoBrowser.enableGrid = true;
        _mwPhotoBrowser.startOnGrid = false;
        _mwPhotoBrowser.enableSwipeToDismiss = true;
        _mwPhotoBrowser.backgroundColor = [UIColor whiteColor];
        _mwPhotoBrowser.trackTintColor = SEAF_COLOR_LIGHT;
        _mwPhotoBrowser.progressColor = SEAF_COLOR_GREY;
        _mwPhotoBrowser.preLoadNumLeft = 0;
        _mwPhotoBrowser.preLoadNumRight = 1;
    }
    return _mwPhotoBrowser;
}

- (SeafPhoto *)getSeafPhoto:(id<SeafPreView>)photo {
    for (SeafPhoto *sphoto in _photos) {
        if (sphoto.file == photo) {
            return sphoto;
        }
    }
    return nil;
}

- (void)clearPhotosVIew
{
    [_mwPhotoBrowser.view removeFromSuperview];
    _photos = nil;
}

#pragma mark - MWPhotoBrowserDelegate
- (NSUInteger)numberOfPhotosInPhotoBrowser:(MWPhotoBrowser *)photoBrowser {
    if (!self.photos) return 0;
    return self.photos.count;
}

- (id <MWPhoto>)photoBrowser:(MWPhotoBrowser *)photoBrowser photoAtIndex:(NSUInteger)index {
    if (index < self.photos.count) {
        return [self.photos objectAtIndex:index];
    }
    return nil;
}

- (NSString *)photoBrowser:(MWPhotoBrowser *)photoBrowser titleForPhotoAtIndex:(NSUInteger)index
{
    if (index < self.photos.count) {
        SeafPhoto *photo = [self.photos objectAtIndex:index];
        return photo.file.name;
    } else {
        Warning("index %lu out of bound %lu", (unsigned long)index, (unsigned long)self.photos.count);
        return nil;
    }
}

- (void)photoBrowser:(MWPhotoBrowser *)photoBrowser didDisplayPhotoAtIndex:(NSUInteger)index
{
    if (index >= self.photos.count) return;
    NSUInteger previousCurrentPage = _currentPageIndex;
    _currentPageIndex = index;
    id<SeafPreView> pre = self.preViewItem;
    self.preViewItem = [[self.photos objectAtIndex:index] file];
    if (_currentPageIndex != previousCurrentPage) {
        if (IsIpad() && [self.masterVc isKindOfClass: [SeafFileViewController class]]) {
            SeafFileViewController *c = (SeafFileViewController *)self.masterVc;
            [c photoSelectedChanged:pre to:self.preViewItem];
        }
    }
    [self updateNavigation];
}

- (BOOL)isPortrait {
    UIDeviceOrientation orientation = (UIDeviceOrientation)[UIApplication sharedApplication].statusBarOrientation;
    if (orientation == UIDeviceOrientationPortrait || orientation == UIDeviceOrientationPortraitUpsideDown) {
        return true;
    } else {
        return false;
    }
}

- (UITextView *)textView {
    if (!_textView) {
        _textView = [[UITextView alloc] initWithFrame:self.view.frame];
        _textView.editable = false;
        _textView.contentInset =UIEdgeInsetsMake(6, 10, 6, 10);
        _textView.alwaysBounceVertical = YES;
    }
    return _textView;
}

- (QLPreviewController *)qlViewController {
    if (!_qlViewController) {
        _qlViewController = [[QLPreviewController alloc] init];
        _qlViewController.delegate = self;
        _qlViewController.dataSource = self;
    }
    return _qlViewController;
}

- (NSAttributedString *)attributedTextOfPreViewItem {
    NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc] initWithFileURL:self.preViewItem.previewItemURL options:@{NSDocumentTypeDocumentAttribute : NSPlainTextDocumentType} documentAttributes:nil error:nil];
    [attributedText addAttributes:@{NSFontAttributeName : [UIFont systemFontOfSize:14.0]} range:NSMakeRange(0, attributedText.length)];
    return attributedText;
}

@end
