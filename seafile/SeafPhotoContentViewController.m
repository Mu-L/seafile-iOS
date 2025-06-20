//
//  SeafPhotoContentViewController.m
//  seafileApp
//
//  Created by henry on 2025/4/17.
//  Copyright © 2025 Seafile. All rights reserved.
//

#import "SeafPhotoContentViewController.h"
#import "SeafPhotoGalleryViewController.h"
#import <ImageIO/ImageIO.h>
#import "FileSizeFormatter.h"
#import "Debug.h"
#import "ExtentedString.h"
#import "SeafConnection.h"
#import <SDWebImage/UIImageView+WebCache.h>
#import "SeafFile.h"
#import "SeafStorage.h"
#import "SeafPreview.h"
#import "SeafPhotoInfoView.h"
#import "SeafUploadFile.h"
#import "SeafErrorPlaceholderView.h"

@interface SeafPhotoContentViewController ()<UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView  *scrollView;
@property (nonatomic, strong) UIImageView   *imageView;
@property (nonatomic, strong) SeafPhotoInfoView *infoView;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
@property (nonatomic, strong) UITapGestureRecognizer *doubleTapGesture;
@property (nonatomic, strong) UIImageView *errorIconImageView;
@property (nonatomic, strong) UILabel *errorLabel;

@end

@implementation SeafPhotoContentViewController

// Custom getter for repoId
- (NSString *)repoId {
    if (self.seafFile && [self.seafFile isKindOfClass:[SeafFile class]]) {
        return ((SeafFile *)self.seafFile).repoId;
    }
    return nil;
}

- (NSString *)filePath {
    if (self.seafFile && [self.seafFile isKindOfClass:[SeafFile class]]) {
        return ((SeafFile *)self.seafFile).path;
    }
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0]; // Light gray background
    [self setupScrollView];
    [self setupInfoView];
    [self setupLoadingIndicator];
    // [self loadImage]; // loadImage will be called by viewWillAppear or explicitly after file is set
    
    // Initialize with info view hidden
    self.infoVisible = NO;
    self.infoView.hidden = YES;
    
    // Initialize placeholder image flag
    self.isDisplayingPlaceholderOrErrorImage = NO;
}

- (void)setupScrollView {
    // Create a scroll view that fills the entire view
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.scrollView.delegate = self;
    self.scrollView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0]; // Light gray background
    // Keep default zoom at 1.0, so the image is displayed at its original scale
    self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.maximumZoomScale = 3.0;
    // Show horizontal and vertical scroll indicators
    self.scrollView.showsHorizontalScrollIndicator = YES;
    self.scrollView.showsVerticalScrollIndicator = YES;
    [self.view addSubview:self.scrollView];

    // Create an image view that matches the size of the scroll view
    self.imageView = [[UIImageView alloc] initWithFrame:self.scrollView.bounds];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit; // Ensure image fits view and maintains aspect ratio
    self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.scrollView addSubview:self.imageView];
    
    // Add tap gesture for toggling UI visibility
    self.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self.scrollView addGestureRecognizer:self.tapGesture];
    
    // Add double tap gesture for zooming
    self.doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    self.doubleTapGesture.numberOfTapsRequired = 2;
    [self.scrollView addGestureRecognizer:self.doubleTapGesture];
    
    // Ensure single tap gesture doesn't interfere with double tap
    [self.tapGesture requireGestureRecognizerToFail:self.doubleTapGesture];
}

- (void)setupInfoView {
    // Create the info view that will display metadata
    CGFloat infoHeight = roundf(self.view.bounds.size.height * 0.6); // 3/5 of screen height
    
    // Position initially off-screen at the bottom
    CGRect infoFrame = CGRectMake(0,
                                  self.view.bounds.size.height,
                                  self.view.bounds.size.width,
                                  infoHeight);
    
    // Create info view with a slightly translucent background
    self.infoView = [[SeafPhotoInfoView alloc] initWithFrame:infoFrame];
    
    // Add autoresizing mask to maintain width and position relative to bottom
    self.infoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    
    // Add to view hierarchy as a top-level view (above scroll view)
    [self.view addSubview:self.infoView];
    
    // Set the delegate for the internal scroll view
    self.infoView.infoScrollView.delegate = self;
    
    // Initially hidden
    self.infoView.hidden = YES;
}

// Update the info view with data from the info model
- (void)updateInfoView {
    self.infoView.infoModel = self.infoModel;
    [self.infoView updateInfoView];
}

// Toggle the info view visibility
- (void)toggleInfoView:(BOOL)show animated:(BOOL)animated {
    // Skip if already in the requested state
    if (show == self.infoVisible) return;
    
    // First update our internal state
    self.infoVisible = show;
    
    // Update gesture recognizers based on info visibility
    [self updateGestureRecognizersForInfoVisibility:show];
    
    // Get parent navigation controller and top view controller for controlling navigation bar and bottom UI
    UIViewController *parentVC = self.parentViewController;
    while (parentVC && ![parentVC isKindOfClass:[UINavigationController class]]) {
        parentVC = parentVC.parentViewController;
    }
    
    if ([parentVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navController = (UINavigationController *)parentVC;
        UIViewController *galleryVC = navController.topViewController;
        
        // When showing info panel
        if (show) {
            // Check if gallery controller has special methods
            BOOL hasSpecialGalleryHandling = NO;
            if ([galleryVC respondsToSelector:@selector(disableScrolling)]) {
                @try {
                    [galleryVC performSelector:@selector(disableScrolling)];
                    hasSpecialGalleryHandling = YES;
                } @catch (NSException *exception) {
                    Debug(@"Exception when calling disableScrolling: %@", exception);
                }
            }
            
            // Special case handling for SeafPhotoGalleryViewController - hide navigation bar with animation
            if (hasSpecialGalleryHandling) {
                // First move thumbnails out of the way immediately
                @try {
                    SeafPhotoGalleryViewController *specificGalleryVC = (SeafPhotoGalleryViewController *)galleryVC;
                    UIView *thumbnailCollection = specificGalleryVC.thumbnailCollection;
                    UIView *toolbarView = specificGalleryVC.toolbarView;
                    
                    // Hide thumbnail view immediately
                    if (thumbnailCollection) {
                        thumbnailCollection.hidden = YES;
                        thumbnailCollection.alpha = 0.0;
                    }
                    
                    // Keep toolbar visible
                    if (toolbarView) {
                        toolbarView.hidden = NO;
                        toolbarView.alpha = 1.0;
                    }
                } @catch (NSException *exception) {
                    Debug(@"Exception when accessing gallery properties: %@", exception);
                }
                
                // Hide navigation bar with fade
                    [UIView animateWithDuration:0.15 animations:^{
                        navController.navigationBar.alpha = 0.0;
                    } completion:^(BOOL finished) {
                        [navController setNavigationBarHidden:YES animated:NO];
                }];
            } else {
                // Normal behavior - add fade transition for hiding navigation bar
                [UIView animateWithDuration:0.15 animations:^{
                    navController.navigationBar.alpha = 0.0;
                } completion:^(BOOL finished) {
                    [navController setNavigationBarHidden:YES animated:NO];
                }];
            }
            
            if ([galleryVC isKindOfClass:[SeafPhotoGalleryViewController class]]) {
                @try {
                    SeafPhotoGalleryViewController *specificGalleryVC = (SeafPhotoGalleryViewController *)galleryVC;
                    UIView *thumbnailCollection = specificGalleryVC.thumbnailCollection;
                    UIView *toolbarView = specificGalleryVC.toolbarView;
                    
                    // Hide thumbnails immediately without animation
                    if (thumbnailCollection) {
                        thumbnailCollection.hidden = YES;
                        thumbnailCollection.alpha = 0.0;
                    }
                    
                    // Keep toolbar visible
                    if (toolbarView) {
                        toolbarView.hidden = NO;
                        toolbarView.alpha = 1.0;
                    }
                } @catch (NSException *exception) {
                    Debug(@"Exception when accessing gallery properties: %@", exception);
                }
            }
        }
        // When hiding info panel, restore navigation bar and thumbnails later
        else {
            // Add fade transition for showing navigation bar
            [navController setNavigationBarHidden:NO animated:NO];
            navController.navigationBar.alpha = 0.0;
            [UIView animateWithDuration:0.15 animations:^{
                navController.navigationBar.alpha = 1.0;
            }];
            
            if ([galleryVC isKindOfClass:[SeafPhotoGalleryViewController class]]) {
                @try {
                    SeafPhotoGalleryViewController *specificGalleryVC = (SeafPhotoGalleryViewController *)galleryVC;
                    UIView *thumbnailCollection = specificGalleryVC.thumbnailCollection;
                    UIView *toolbarView = specificGalleryVC.toolbarView;
                    
                    // Keep toolbar visible
                    if (toolbarView) {
                        toolbarView.hidden = NO;
                        toolbarView.alpha = 1.0;
                    }
                    
                    // Keep thumbnails hidden until info panel animation completes
                    if (thumbnailCollection) {
                        thumbnailCollection.hidden = YES;
                        thumbnailCollection.alpha = 0.0;
                    }
                } @catch (NSException *exception) {
                    Debug(@"Exception when accessing gallery properties: %@", exception);
                }
            }
        }
    }
    
    // If we need to show the info view, make sure it's updated and visible
    if (show) {
        [self updateInfoView];
        self.infoView.hidden = NO;
        
        // Also display EXIF data if we have an image
        if (self.seafFile) {
            if ([self.seafFile isKindOfClass:[SeafFile class]]) {
                // If we have a file path, get the data to display EXIF info
                if (((SeafFile *)self.seafFile).ooid) {
                    NSString *path = [SeafStorage.sharedObject documentPath:((SeafFile *)self.seafFile).ooid];
                    NSData *data = [NSData dataWithContentsOfFile:path];
                    if (data) {
                        [self displayExifData:data];
                    }
                }
            } else if ([self.seafFile isKindOfClass:[SeafUploadFile class]]) {
                // For upload files, get data from the associated asset
                [((SeafUploadFile *)self.seafFile) getDataForAssociatedAssetWithCompletion:^(NSData * _Nullable data, NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (data) {
                            [self displayExifData:data];
                        }
                    });
                }];
            }
        }
    }
    
    // Get bounds for calculations - these won't change during animation
    CGRect bounds = self.view.bounds;
    CGFloat infoHeight = roundf(bounds.size.height * 0.6); // 3/5 of height for info view
    CGFloat scrollHeight = roundf(bounds.size.height * 0.4); // 2/5 of height for scroll view
    
    // For non-animated transitions
    if (!animated) {
        // Update info panel position immediately
        if (show) {
            // Slide info panel up to show 3/5 of screen
            self.infoView.frame = CGRectMake(0, scrollHeight, bounds.size.width, infoHeight);
        } else {
            // Slide info panel down off screen
            self.infoView.frame = CGRectMake(0, bounds.size.height, bounds.size.width, infoHeight);
        }
        
        // Update scroll view frame without animation
        [self updateScrollViewForInfoVisibility:show animated:NO];
        
        // Hide the info view if we're hiding it
        if (!show) {
            self.infoView.hidden = YES;
            [self showThumbnailCollectionAfterInfoHidden];
        }
        
        return;
    }
    
    // Save current state before animation
    CGPoint contentOffset = self.scrollView.contentOffset;
    CGFloat zoomScale = self.scrollView.zoomScale;
    
    // Calculate target frames
    CGRect infoTargetFrame = show ?
        CGRectMake(0, scrollHeight, bounds.size.width, infoHeight) :
        CGRectMake(0, bounds.size.height, bounds.size.width, infoHeight);
        
    // Calculate scroll view target frame
    CGRect targetScrollFrame;
    
    if (show) {
        // When showing info, calculate proper scroll view position
        CGFloat visibleAreaCenterY = scrollHeight / 2.0; // Center of top 2/5 area
        CGFloat yOffset = visibleAreaCenterY - (bounds.size.height / 2.0);
        targetScrollFrame = CGRectMake(0, yOffset, bounds.size.width, bounds.size.height);
    } else {
        // When hiding info, scroll view takes full screen
        targetScrollFrame = bounds;
    }
    
    // Animated version
    if (show) {
        // Position info view initially off-screen
        self.infoView.frame = CGRectMake(0, bounds.size.height, bounds.size.width, infoHeight);
        
        // Animate both the info panel and scroll view together
        [UIView animateWithDuration:0.2
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            // Slide info panel up
            self.infoView.frame = infoTargetFrame;
            
            // Move scroll view to target position
            self.scrollView.frame = targetScrollFrame;

            // If the error placeholder view is visible, move it along with the scroll view
            if (self.errorPlaceholderView && self.errorPlaceholderView.superview) {
                CGRect placeholderFrame = targetScrollFrame;
                placeholderFrame.origin.y += 30.0; // Adjust position to be a bit lower
                self.errorPlaceholderView.frame = placeholderFrame;
            }
            
            // Restore content offset and scale
            self.scrollView.contentOffset = contentOffset;
            self.scrollView.zoomScale = zoomScale;
            
            // Update image center with animation
            [self scrollViewDidZoom:self.scrollView];
        } completion:^(BOOL finished) {
            // Ensure content is properly centered after animation
            [self centerZoomedImageIfNeeded];
        }];
    } else {
        // Animate both info panel sliding down and scroll view moving back to full screen
        [UIView animateWithDuration:0.2
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            // Slide info panel down
            self.infoView.frame = infoTargetFrame;
            
            // Move scroll view to target position
            self.scrollView.frame = targetScrollFrame;

            // If the error placeholder view is visible, move it along with the scroll view
            if (self.errorPlaceholderView && self.errorPlaceholderView.superview) {
                CGRect placeholderFrame = targetScrollFrame;
                placeholderFrame.origin.y += 30.0; // Adjust position to be a bit lower
                self.errorPlaceholderView.frame = placeholderFrame;
            }
            
            // Restore content offset and scale
            self.scrollView.contentOffset = contentOffset;
            self.scrollView.zoomScale = zoomScale;
            
            // Update image center with animation
            [self scrollViewDidZoom:self.scrollView];
        } completion:^(BOOL finished) {
            // After animation completes, hide the info view
            self.infoView.hidden = YES;
            
            // Ensure content is properly centered
            [self centerZoomedImageIfNeeded];
            
            // Show thumbnails after info panel is hidden
            [self showThumbnailCollectionAfterInfoHidden];
        }];
    }
}

// Helper method to update scroll view frame separately from info panel animation
- (void)updateScrollViewForInfoVisibility:(BOOL)infoVisible animated:(BOOL)animated {
    CGRect bounds = self.view.bounds;
    CGFloat scrollHeight = roundf(bounds.size.height * 0.4); // 2/5 of height for scroll view
    
    // Save current state
    CGPoint contentOffset = self.scrollView.contentOffset;
    CGFloat zoomScale = self.scrollView.zoomScale;
    
    // Calculate target frame
    CGRect targetFrame;
    
    if (infoVisible) {
        // Calculate the center point of the top 2/5 area - it should be at 1/5 of screen height from top
        CGFloat visibleAreaCenterY = scrollHeight / 2.0; // Center of top 2/5 area
        
        // Use negative y-offset to position the scroll view's center at the center of the visible area
        CGFloat yOffset = visibleAreaCenterY - (bounds.size.height / 2.0);
        targetFrame = CGRectMake(0, yOffset, bounds.size.width, bounds.size.height);
    } else {
        // When info is hidden, scroll view takes full screen
        targetFrame = bounds;
    }
    
    // Apply changes with or without animation
    if (animated) {
        [UIView animateWithDuration:0.2 animations:^{
            self.scrollView.frame = targetFrame;

            // If the error placeholder view is visible, move it along with the scroll view
            if (self.errorPlaceholderView && self.errorPlaceholderView.superview) {
                CGRect placeholderFrame = targetFrame;
                if (infoVisible) {
                    placeholderFrame.origin.y += 30.0; // Adjust position to be a bit lower
                }
                self.errorPlaceholderView.frame = placeholderFrame;
            }
            
            // Restore offset and scale
            self.scrollView.contentOffset = contentOffset;
            self.scrollView.zoomScale = zoomScale;
            
            // Update image center with animation
            [self scrollViewDidZoom:self.scrollView];
        } completion:^(BOOL finished) {
            // Ensure content is properly centered after animation
            [self centerZoomedImageIfNeeded];
        }];
    } else {
        // Apply changes immediately
        self.scrollView.frame = targetFrame;

        // If the error placeholder view is visible, move it along with the scroll view
        if (self.errorPlaceholderView && self.errorPlaceholderView.superview) {
            CGRect placeholderFrame = targetFrame;
            if (infoVisible) {
                placeholderFrame.origin.y += 30.0; // Adjust position to be a bit lower
            }
            self.errorPlaceholderView.frame = placeholderFrame;
        }
        
        // Restore offset and scale
        self.scrollView.contentOffset = contentOffset;
        self.scrollView.zoomScale = zoomScale;
        
        // Center the content within the visible area
        [self centerZoomedImageIfNeeded];
    }
    
    // Force immediate layout update
    [self.scrollView setNeedsLayout];
    [self.scrollView layoutIfNeeded];
}

// Helper method to update frames based on info visibility - separate from animation
- (void)updateViewFramesForInfoVisibility:(BOOL)infoVisible {
    CGRect bounds = self.view.bounds;
    CGFloat infoHeight = roundf(bounds.size.height * 0.6); // 3/5 of height for info view
    CGFloat scrollHeight = roundf(bounds.size.height * 0.4); // 2/5 of height for scroll view
    
    // Update info panel position
    if (infoVisible) {
        self.infoView.frame = CGRectMake(0, scrollHeight, bounds.size.width, infoHeight);
    } else {
        self.infoView.frame = CGRectMake(0, bounds.size.height, bounds.size.width, infoHeight);
    }
    
    // Update scroll view separately - use NO for animation to avoid unwanted animations during layout updates
    [self updateScrollViewForInfoVisibility:infoVisible animated:NO];
}

// Show thumbnails after hiding info panel
- (void)showThumbnailCollectionAfterInfoHidden {
    UIViewController *parentVC = self.parentViewController;
    while (parentVC && ![parentVC isKindOfClass:[UINavigationController class]]) {
        parentVC = parentVC.parentViewController;
    }
    
    if ([parentVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navController = (UINavigationController *)parentVC;
        UIViewController *galleryVC = navController.topViewController;
        
        if ([galleryVC isKindOfClass:[SeafPhotoGalleryViewController class]]) {
            @try {
                SeafPhotoGalleryViewController *specificGalleryVC = (SeafPhotoGalleryViewController *)galleryVC;
                UIView *thumbnailCollection = specificGalleryVC.thumbnailCollection;
                if (thumbnailCollection) {
                    // Add fade-in animation effect instead of showing immediately
                    thumbnailCollection.hidden = NO;
                    thumbnailCollection.alpha = 0.0;
                    
                    [UIView animateWithDuration:0.15
                                          delay:0.0
                                        options:UIViewAnimationOptionCurveEaseIn
                                     animations:^{
                        thumbnailCollection.alpha = 1.0;
                    } completion:nil];
                }
            } @catch (NSException *exception) {
                Debug(@"Exception when accessing gallery properties: %@", exception);
            }
        }
    }
}

// Helper method to enable/disable gesture recognizers based on info visibility
- (void)updateGestureRecognizersForInfoVisibility:(BOOL)infoVisible {
    // When info is hidden, enable gestures for normal interaction
    self.tapGesture.enabled = !infoVisible;
    self.doubleTapGesture.enabled = !infoVisible;
}

// Helper method to center image after frame changes
- (void)centerZoomedImageIfNeeded {
    // Call scrollViewDidZoom to re-center the image with the updated frame
    [self scrollViewDidZoom:self.scrollView];
}

// Handle tap to toggle UI visibility
- (void)handleTap:(UITapGestureRecognizer *)gesture {
    // Get parent navigation controller
    UIViewController *parentVC = self.parentViewController;
    while (parentVC && ![parentVC isKindOfClass:[UINavigationController class]]) {
        parentVC = parentVC.parentViewController;
    }
    
    if ([parentVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navController = (UINavigationController *)parentVC;
        
        // Toggle navigation bar visibility
        BOOL isHidden = navController.navigationBar.hidden;
        
        // Use fade transition instead of standard animation
        if (isHidden) {
            // Show navigation bar with fade in effect
            [navController setNavigationBarHidden:NO animated:NO];
            navController.navigationBar.alpha = 0.0;
            [UIView animateWithDuration:0.15 animations:^{
                navController.navigationBar.alpha = 1.0;
            }];
        } else {
            // Hide navigation bar with fade out effect
            [UIView animateWithDuration:0.15 animations:^{
                navController.navigationBar.alpha = 0.0;
            } completion:^(BOOL finished) {
                [navController setNavigationBarHidden:YES animated:NO];
            }];
        }
        
        // Find SeafPhotoGalleryViewController
        UIViewController *galleryVC = navController.topViewController;
        if ([galleryVC isKindOfClass:[SeafPhotoGalleryViewController class]]) {
            // Try to get and toggle thumbnail collection visibility
            @try {
                SeafPhotoGalleryViewController *specificGalleryVC = (SeafPhotoGalleryViewController *)galleryVC;
                UIView *thumbnailCollection = specificGalleryVC.thumbnailCollection;
                UIView *toolbarView = specificGalleryVC.toolbarView;
                // Get overlay views
                UIView *leftOverlay = specificGalleryVC.leftThumbnailOverlay;
                UIView *rightOverlay = specificGalleryVC.rightThumbnailOverlay;
                
                if (isHidden) {
                    // Restore from hidden state - first set visible but transparent, then fade in
                    if (thumbnailCollection && [thumbnailCollection isKindOfClass:[UIView class]]) {
                        thumbnailCollection.hidden = NO;
                        thumbnailCollection.alpha = 0.0;
                    }
                    
                    if (toolbarView && [toolbarView isKindOfClass:[UIView class]]) {
                        toolbarView.hidden = NO;
                        toolbarView.alpha = 0.0;
                    }

                    // Prepare overlays for fade-in
                    if (leftOverlay) leftOverlay.alpha = 0.0;
                    if (rightOverlay) rightOverlay.alpha = 0.0;
                    // Note: Overlays' .hidden state is managed by SeafPhotoGalleryViewController based on thumbnailCollection.hidden and scroll state.
                    
                    // Start fade-in animation, while changing background color from black to white
                    [UIView animateWithDuration:0.15
                                          delay:0.05
                                        options:UIViewAnimationOptionCurveEaseIn
                                     animations:^{
                        // Restore thumbnail and toolbar visibility
                        if (thumbnailCollection) thumbnailCollection.alpha = 1.0;
                        if (toolbarView) toolbarView.alpha = 1.0;
                        // Fade in overlays
                        if (leftOverlay) leftOverlay.alpha = 1.0;
                        if (rightOverlay) rightOverlay.alpha = 1.0;
                        
                        // Change background color from black to light gray
                        self.view.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
                        self.scrollView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
                        self.imageView.backgroundColor = [UIColor clearColor];
                    } completion:nil];
                    
                } else {
                    // Switch to hidden state - fade out then set to hidden, while changing background color from white to black
                    [UIView animateWithDuration:0.15
                                     animations:^{
                        // Hide thumbnail and toolbar
                        if (thumbnailCollection) thumbnailCollection.alpha = 0.0;
                        if (toolbarView) toolbarView.alpha = 0.0;
                        // Fade out overlays
                        if (leftOverlay) leftOverlay.alpha = 0.0;
                        if (rightOverlay) rightOverlay.alpha = 0.0;
                        
                        // Change background color from gray to black
                        self.view.backgroundColor = [UIColor blackColor];
                        self.scrollView.backgroundColor = [UIColor blackColor];
                        self.imageView.backgroundColor = [UIColor clearColor];
                    } completion:^(BOOL finished) {
                        if (thumbnailCollection) thumbnailCollection.hidden = YES;
                        if (toolbarView) toolbarView.hidden = YES;
                        // Hide overlays after animation
                        if (leftOverlay) leftOverlay.hidden = YES;
                        if (rightOverlay) rightOverlay.hidden = YES;
                    }];
                }
            } @catch (NSException *exception) {
                // Handle possible exceptions to maintain app stability
                Debug(@"Exception when accessing gallery properties: %@", exception);
            }
        }
        
        // Set status bar style - adjust status bar style based on background color
        if (@available(iOS 13.0, *)) {
            UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            while (topVC.presentedViewController) {
                topVC = topVC.presentedViewController;
            }
            
            // When background is black, status bar should be light; when background is white, status bar should be dark
            if ([topVC isKindOfClass:[UINavigationController class]]) {
                UINavigationController *navVC = (UINavigationController *)topVC;
                navVC.navigationBar.barStyle = isHidden ? UIBarStyleBlackTranslucent : UIBarStyleBlack;
            }
            
            // Update status bar preference
            [topVC setNeedsStatusBarAppearanceUpdate];
        } else {
            [[UIApplication sharedApplication] setStatusBarHidden:!isHidden withAnimation:UIStatusBarAnimationFade];
            [[UIApplication sharedApplication] setStatusBarStyle:isHidden ? UIStatusBarStyleDefault : UIStatusBarStyleLightContent animated:YES];
        }
    }
}

- (void)loadImage {
    // At the beginning of loadImage, remove any existing error view
    if (self.errorPlaceholderView) {
        [self.errorPlaceholderView removeFromSuperview];
        self.errorPlaceholderView = nil;
    }
    self.isDisplayingPlaceholderOrErrorImage = NO; // Reset flag

    self.imageView.image = nil; // Clear previous image before loading new one
    // If seafFile is available, use it to load the image
    if (self.seafFile && [self.seafFile isKindOfClass:[SeafFile class]]) {
        Debug(@"[PhotoContent] loadImage called for %@, seafFile: %@, has ooid: %@", self.photoURL, self.seafFile.name, ((SeafFile *)self.seafFile).ooid ? @"YES" : @"NO");

        // Only show indicator if the file is NOT yet downloaded/cached (ooid is nil)
        if (![self.seafFile hasCache]) {
            [self showLoadingIndicator];
            Debug(@"[PhotoContent] File needs download, showing indicator: %@", self.seafFile.name);
            // If we have repoId and filePath, fetch file metadata from API (can happen concurrently)
            if (self.repoId && self.filePath) {
                [self fetchFileMetadata];
            }
            return;
        } else {
            // Add a loading indicator while we load the image (might be large)
            [self showLoadingIndicator];
            
            // File exists, proceed with loading
            [((SeafFile *)self.seafFile) getImageWithCompletion:^(UIImage *image) {
                Debug(@"[PhotoContent] getImageWithCompletion callback for %@, image: %@", self.seafFile.name, image ? @"SUCCESS" : @"FAILED");
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Check if this view controller is still active and valid
                    if (!self.view.window) {
                        Debug(@"[PhotoContent] View is no longer visible, skipping image update for %@", self.seafFile.name);
                        [self hideLoadingIndicator];
                        return;
                    }
                    
                    if (image) {
                        // This prevents the brief flash of white/blank screen
                        self.imageView.image = image;
                        self.isDisplayingPlaceholderOrErrorImage = NO; // Clear flag when setting real image
                        [self updateScrollViewContentSize];
                        Debug(@"[PhotoContent] Image set successfully for %@", self.seafFile.name);
                        
                        // Ensure error view is removed if it was somehow still there
                        if (self.errorPlaceholderView) {
                            [self.errorPlaceholderView removeFromSuperview];
                            self.errorPlaceholderView = nil;
                        }
                        self.isDisplayingPlaceholderOrErrorImage = NO; // Ensure flag is cleared on success

                        // If we have the file path, get the data to display EXIF info
                        if (((SeafFile *)self.seafFile).ooid) {
                            NSString *path = [SeafStorage.sharedObject documentPath:((SeafFile *)self.seafFile).ooid];
                            NSData *data = [NSData dataWithContentsOfFile:path];
                            if (data) {
                                [self displayExifData:data];
                            } else {
                                Debug(@"[PhotoContent] WARNING: Could not read file data for EXIF from path: %@", path);
                            }
                        }
                        // Explicitly hide indicator AFTER image is set
                        [self hideLoadingIndicator];
                        Debug(@"[PhotoContent] Image loading complete, indicator hidden for %@", self.seafFile.name);
                    } else {
                        Debug(@"[PhotoContent] Image loading failed for %@", self.seafFile.name);
                        // self.imageView.image = [UIImage imageNamed:@"gallery_failed.png"];
                        // self.isDisplayingPlaceholderOrErrorImage = YES; // Set flag when setting error image
                        [self showErrorImage];
                        [self clearExifDataView];
                        // Explicitly hide indicator even on failure
                        [self hideLoadingIndicator];
                    }
                });
            }];
            
            // Fetch metadata if needed (can happen concurrently)
            if (self.repoId && self.filePath) {
                [self fetchFileMetadata];
            }
            return;
        }
    }
    else if ([self.seafFile isKindOfClass:[SeafUploadFile class]]) {
        [((SeafUploadFile *)self.seafFile) getImageWithCompletion:^(UIImage *image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Check if this view controller is still active and valid
                if (!self.view.window) {
                    Debug(@"[PhotoContent] View is no longer visible, skipping image update for %@", self.seafFile.name);
                    [self hideLoadingIndicator];
                    return;
                }
                
                if (image) {
                    // This prevents the brief flash of white/blank screen
                    self.imageView.image = image;
                    self.isDisplayingPlaceholderOrErrorImage = NO; // Clear flag when setting real image
                    [self updateScrollViewContentSize];
                    Debug(@"[PhotoContent] Image set successfully for %@", self.seafFile.name);
                    
                    // Ensure error view is removed if it was somehow still there
                    if (self.errorPlaceholderView) {
                        [self.errorPlaceholderView removeFromSuperview];
                        self.errorPlaceholderView = nil;
                    }
                    self.isDisplayingPlaceholderOrErrorImage = NO; // Ensure flag is cleared on success

                    // If we have the file path, get the data to display EXIF info
                    [((SeafUploadFile *)self.seafFile) getDataForAssociatedAssetWithCompletion:^(NSData * _Nullable data, NSError * _Nullable error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (data) {
                                [self displayExifData:data];
                            } else {
                                Debug(@"[PhotoContent] WARNING: Could not read file data for EXIF from uploadImage: %@", self.seafFile.name);
                            }
                            // Explicitly hide indicator AFTER image is set
                            [self hideLoadingIndicator];
                        });
                    }];
                   
                    Debug(@"[PhotoContent] Image loading complete, indicator hidden for %@", self.seafFile.name);
                } else {
                    Debug(@"[PhotoContent] Image loading failed for %@", self.seafFile.name);
                    [self showErrorImage];
                    [self clearExifDataView];
                    // Explicitly hide indicator even on failure
                    [self hideLoadingIndicator];
                }
            });

        }];
        return;
    }
    else {
        Debug(@"[PhotoContent] No SeafFile available to show image");
        [self showErrorImage];
        [self hideLoadingIndicator];
    }
}

// Add method to fetch file metadata from API
- (void)fetchFileMetadata {
    if (!self.repoId || !self.filePath) {
        Debug(@"Cannot fetch file metadata: repoId or filePath is missing");
        return;
    }
    
    // Use the connection property instead of getting it from app delegate
    if (!self.connection || !self.connection.authorized) {
        Debug(@"No valid connection available for API request");
        return;
    }
    
    // Build the API URL
    NSString *requestUrl = [NSString stringWithFormat:@"%@/repos/%@/file/detail/?p=%%2F%@", API_URL, self.repoId, [self.filePath escapedUrl]];
    Debug(@"Fetching file metadata from URL: %@", requestUrl);
    
    // Use SeafConnection's sendRequest method
    [self.connection sendRequest:requestUrl
                    success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON) {
        // Handle success response
        if (!JSON) {
            Debug(@"No data received from file metadata API");
            return;
        }
        
        // Log the response for debugging
        Debug(@"File metadata response: %@", JSON);
        
        // Extract the needed information
        NSNumber *fileSize = JSON[@"size"];
        NSString *lastModified = JSON[@"last_modified"];
        NSString *lastModifierName = JSON[@"last_modifier_name"];
        NSString *lastModifierAvatar = JSON[@"last_modifier_avatar"]; // Avatar URL field
        
        // Create info model dictionary with the extracted data
        NSMutableDictionary *infoDict = [NSMutableDictionary dictionary];
        
        if (fileSize) {
            [infoDict setObject:[fileSize stringValue] forKey:@"Size"];
        }
        
        if (lastModified) {
            [infoDict setObject:lastModified forKey:@"Modified"];
        }
        
        if (lastModifierName) {
            [infoDict setObject:lastModifierName forKey:@"Owner"];
        }
        
        // If avatar URL exists, add it to the data model
        if (lastModifierAvatar) {
            [infoDict setObject:lastModifierAvatar forKey:@"OwnerAvatar"];
        }
        
        // Update the infoModel on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            self.infoModel = infoDict;
            
            // Update the info view if it's visible
            if (self.infoVisible) {
                [self updateInfoView];
            }
        });
    }
    failure:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON, NSError *error) {
        Debug(@"Error fetching file metadata: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.imageView.image && !self.isDisplayingPlaceholderOrErrorImage) {
                 // for metadata failure, we just log it. The user experience is primarily driven by image display.
            }
        });
    }];
}

// Update displayExifData to use the new InfoView
- (void)displayExifData:(NSData *)data {
    [self.infoView displayExifData:data];
}

// Update clearExifDataView to use the new InfoView
- (void)clearExifDataView {
    [self.infoView clearExifDataView];
}

#pragma mark - UIScrollViewDelegate
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    // Save current zoom scale
    CGFloat savedZoomScale = self.scrollView.zoomScale;
    
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        // Reset zoom
        self.scrollView.zoomScale = 1.0;
        
        // Update zoom range and center
        [self updateZoomScalesForSize:size];
        [self scrollViewDidZoom:self.scrollView];
        
        // Refresh info view to adapt to new width
        if (self.infoVisible) {
            [self updateInfoView];
        }
        
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        // Restore zoom scale
        if (savedZoomScale != 1.0) {
            self.scrollView.zoomScale = MIN(savedZoomScale, self.scrollView.maximumZoomScale);
        }
    }];
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    // Center image in scroll view as user zooms
    CGFloat offsetX = MAX((scrollView.bounds.size.width - scrollView.contentSize.width) * 0.5, 0.0);
    CGFloat offsetY = MAX((scrollView.bounds.size.height - scrollView.contentSize.height) * 0.5, 0.0);
    
    // If info panel is visible, we need to adjust vertical centering for the top 2/5 visible area
    if (self.infoVisible) {
        // Calculate the visible area height (2/5 of screen height)
        CGFloat visibleAreaHeight = self.view.bounds.size.height * 0.4; // 2/5 of screen
        CGFloat visibleAreaCenterY = visibleAreaHeight / 2.0; // Center point of visible area
        
        // When scrollView's frame is larger than its visible portion, we need special handling
        if (scrollView.contentSize.height < visibleAreaHeight) {
            // Calculate adjustment to center content in the visible area (top 2/5 of screen)
            // The scroll view's center is at visibleAreaCenterY (1/5 of screen height from top)
            CGFloat scrollViewCenterY = (scrollView.bounds.size.height / 2.0) + scrollView.frame.origin.y;
            offsetY = visibleAreaCenterY - scrollViewCenterY + (visibleAreaHeight - scrollView.contentSize.height) / 2.0;
        }
    }
    
    // Update image center position
    self.imageView.center = CGPointMake(scrollView.contentSize.width * 0.5 + offsetX,
                                       scrollView.contentSize.height * 0.5 + offsetY);
}

// Handle double tap gesture
- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    // Check if current zoom level is near minimum
    if (self.scrollView.zoomScale < self.scrollView.maximumZoomScale / 2) {
        // Zoom to maximum zoom level
        CGPoint location = [gesture locationInView:self.imageView];
        CGSize size = self.scrollView.bounds.size;
        
        CGRect zoomRect = CGRectMake(location.x - (size.width / 4),
                                     location.y - (size.height / 4),
                                     size.width / 2,
                                     size.height / 2);
        
        [self.scrollView zoomToRect:zoomRect animated:YES];
    } else {
        // Zoom to minimum zoom level
        [self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:YES];
    }
}

- (void)setInfoVisible:(BOOL)infoVisible {
    if (_infoVisible != infoVisible) {
        _infoVisible = infoVisible;
        [self updateGestureRecognizersForInfoVisibility:infoVisible];
    }
}

#pragma mark - Loading Indicator Methods

- (void)showLoadingIndicator {
    Debug(@"[PhotoContent] showLoadingIndicator called for %@", self.seafFile ? self.seafFile.name : self.photoURL);
    
    // Ensure this runs on the main thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLoadingIndicator];
        });
        return;
    }
    
    // Ensure indicator exists and is created if needed
    if (!self.activityIndicator || !self.progressLabel) {
        Debug(@"[PhotoContent] Creating loading indicators that were not initialized for %@", self.seafFile ? self.seafFile.name : @"unknown");
        [self setupLoadingIndicator];
    }
    
    // Only start animating if not already animating
    if (!self.activityIndicator.isAnimating) {
        [self.activityIndicator startAnimating];
        self.progressLabel.text = @"0%";
        self.progressLabel.hidden = NO;
        [self.view bringSubviewToFront:self.activityIndicator];
        [self.view bringSubviewToFront:self.progressLabel];
        Debug(@"[PhotoContent] Loading indicator now visible for %@", self.seafFile ? self.seafFile.name : self.photoURL);
    }
}

- (void)hideLoadingIndicator {
    Debug(@"[PhotoContent] hideLoadingIndicator called for %@", self.seafFile ? self.seafFile.name : self.photoURL);
    
    // Ensure this runs on the main thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideLoadingIndicator];
        });
        return;
    }
    
    // Remove all indicators to ensure none are left behind
    [self cleanupAllLoadingIndicators];
    
    Debug(@"[PhotoContent] Loading indicators hidden and cleaned up for %@", self.seafFile ? self.seafFile.name : self.photoURL);
}

// More thorough cleanup of all loading indicators
- (void)cleanupAllLoadingIndicators {
    // Stop the main activity indicator if it exists
    if (self.activityIndicator && [self.activityIndicator isAnimating]) {
        [self.activityIndicator stopAnimating];
    }
    
    // Hide the main progress label if it exists
    if (self.progressLabel) {
        self.progressLabel.hidden = YES;
    }
    
    // Find and remove any other activity indicators or percentage labels that might exist
    for (UIView *subview in self.view.subviews) {
        // Check for any UIActivityIndicatorView
        if ([subview isKindOfClass:[UIActivityIndicatorView class]]) {
            UIActivityIndicatorView *indicator = (UIActivityIndicatorView *)subview;
            [indicator stopAnimating];
            
            // If it's not our main indicator, remove it
            if (indicator != self.activityIndicator) {
                Debug(@"[PhotoContent] Removing extra indicator: %@", indicator);
                [indicator removeFromSuperview];
            }
        }
        // Check for any UILabel with percentage text
        else if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            NSString *text = label.text;
            
            // If it's a percentage label and not our main one, remove it
            if (text && ([text hasSuffix:@"%"] || label.tag == 1002) && label != self.progressLabel) {
                Debug(@"[PhotoContent] Removing extra progress label: %@", label);
                [label removeFromSuperview];
            }
        }
    }
}

- (void)updateLoadingProgress:(float)progress {
    // Ensure this runs on the main thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateLoadingProgress:progress];
        });
        return;
    }
    
    // Ensure we have loading indicators
    if (!self.activityIndicator || !self.progressLabel) {
        Debug(@"[PhotoContent] Creating loading indicators before updating progress for %@", self.seafFile ? self.seafFile.name : @"unknown");
        [self setupLoadingIndicator];
    }
    
    // Only update if we have valid indicators
    if (self.activityIndicator && self.progressLabel) {
        // Start animating if not already
        if (!self.activityIndicator.isAnimating) {
            [self.activityIndicator startAnimating];
            [self.view bringSubviewToFront:self.activityIndicator];
        }
        
        // Update text and ensure visible
        self.progressLabel.text = [NSString stringWithFormat:@"%.0f%%", progress * 100];
        self.progressLabel.hidden = NO;
        [self.view bringSubviewToFront:self.progressLabel];
        
        Debug(@"[PhotoContent] Updated progress to %.0f%% for %@", progress * 100, self.seafFile ? self.seafFile.name : self.photoURL);
    }
}

// Sets an error image to display when loading fails
- (void)showErrorImage {
    Debug(@"[PhotoContent] Showing error image for %@", self.seafFile ? self.seafFile.name : self.photoURL);

    // Ensure this runs on the main thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showErrorImage];
        });
        return;
    }

    // Clear the main image view content
    self.imageView.image = nil;
    self.isDisplayingPlaceholderOrErrorImage = YES;

    // Remove existing error view if any to prevent duplicates
    if (self.errorPlaceholderView) {
        [self.errorPlaceholderView removeFromSuperview];
        self.errorPlaceholderView = nil;
    }

    // Create the new SeafErrorPlaceholderView
    self.errorPlaceholderView = [[SeafErrorPlaceholderView alloc] initWithFrame:self.view.bounds];
    // The autoresizingMask is set within SeafErrorPlaceholderView's initWithFrame

    // Disable the main tap gesture when error view is visible
    self.tapGesture.enabled = NO;

    // Set the retry action block
    __weak typeof(self) weakSelf = self;
    self.errorPlaceholderView.retryActionBlock = ^{
        // Call the existing retry tap handler
        // We pass nil because the gesture recognizer isn't strictly needed by handleRetryTap's core logic anymore
        [weakSelf handleRetryTap:nil]; 
    };

    // [self.view addSubview:self.errorPlaceholderView];
    // [self.view bringSubviewToFront:self.errorPlaceholderView];
    [self.view insertSubview:self.errorPlaceholderView belowSubview:self.infoView];

    // Update scroll view content size (imageView.image is nil, so contentSize should be minimal)
    [self updateScrollViewContentSize];

    // Clear any EXIF data
    [self clearExifDataView];

    // Make sure the loading indicator is hidden
    [self hideLoadingIndicator];

    Debug(@"[PhotoContent] Error placeholder view set and loading indicator hidden for %@", self.seafFile ? self.seafFile.name : self.photoURL);
}

// Method to handle the retry tap
- (void)handleRetryTap:(UITapGestureRecognizer *)gesture {
    Debug(@"[PhotoContent] Retry tapped for %@", self.seafFile ? self.seafFile.name : self.photoURL);
    // Remove the error view before retrying
    if (self.errorPlaceholderView) {
        [self.errorPlaceholderView removeFromSuperview];
        self.errorPlaceholderView = nil;
    }
    self.isDisplayingPlaceholderOrErrorImage = NO; // Reset flag

    // Re-enable the main tap gesture before attempting retry
    self.tapGesture.enabled = YES;

    // Notify delegate to retry loading
    if (self.delegate && [self.delegate respondsToSelector:@selector(photoContentViewControllerRequestsRetryForFile:atIndex:)]) {
        // We need the index of this content view controller.
        // The view.tag should hold the index set by SeafPhotoGalleryViewController.
        NSUInteger currentIndex = self.view.tag;
        if (self.seafFile) { // Ensure seafFile is not nil
            [self.delegate photoContentViewControllerRequestsRetryForFile:self.seafFile atIndex:currentIndex];
            [self showLoadingIndicator]; // Show loading indicator immediately in the content view
        } else {
            Debug(@"[PhotoContent] Cannot retry: seafFile is nil.");
            // Optionally, show error again if seafFile is nil, as retry isn't possible
            [self showErrorImage]; 
        }
    } else {
        Debug(@"[PhotoContent] Delegate not set or does not respond to retry selector. Cannot retry.");
        // Fallback or error handling if delegate is not correctly set up
        // For example, re-show the error image as retry is not possible through delegate
        [self showErrorImage];
    }
}

// Ensure indicator remains centered during layout changes
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // Re-center indicator and label
    self.activityIndicator.center = self.view.center;
    self.progressLabel.center = CGPointMake(self.view.center.x, self.view.center.y + self.activityIndicator.bounds.size.height / 2 + 25);

    // If the error placeholder view is visible, re-layout its contents
    // This part is now handled by SeafErrorPlaceholderView's layoutSubviews
    /*
    if (self.errorPlaceholderView && self.errorPlaceholderView.superview) {
        self.errorPlaceholderView.frame = self.view.bounds; // Ensure it fills the view

        // Recalculate sizes and positions for error icon and label
        CGFloat iconSize = self.errorIconImageView.frame.size.width; // This property is gone
        if (iconSize == 0 && self.errorIconImageView.image) { // This property is gone
             iconSize = 130.0; // default size
             self.errorIconImageView.frame = CGRectMake(0,0,iconSize,iconSize); // This property is gone
        }
        [self.errorLabel sizeToFit]; // This property is gone

        CGFloat spacingBetweenIconAndLabel = 8.0;
        CGFloat totalContentHeight = self.errorIconImageView.frame.size.height + spacingBetweenIconAndLabel + self.errorLabel.frame.size.height; // These properties are gone
        
        CGFloat startY = (self.errorPlaceholderView.bounds.size.height - totalContentHeight) / 2.0 - 25.0;

        self.errorIconImageView.frame = CGRectMake(
            (self.errorPlaceholderView.bounds.size.width - self.errorIconImageView.frame.size.width) / 2.0,
            startY,
            self.errorIconImageView.frame.size.width,
            self.errorIconImageView.frame.size.height
        ); // These properties are gone

        // Ensure the label width doesn't exceed the placeholder view width with some padding
        CGFloat maxLabelWidth = self.errorPlaceholderView.bounds.size.width - 40; // 20px padding on each side
        CGRect currentLabelFrame = self.errorLabel.frame; // This property is gone
        currentLabelFrame.size.width = MIN(currentLabelFrame.size.width, maxLabelWidth);
        
        self.errorLabel.frame = CGRectMake(
            (self.errorPlaceholderView.bounds.size.width - currentLabelFrame.size.width) / 2.0,
            startY + self.errorIconImageView.frame.size.height + spacingBetweenIconAndLabel,
            currentLabelFrame.size.width,
            currentLabelFrame.size.height
        ); // These properties are gone
    }
    */

    // Update frames based on current state
    [self updateViewFramesForInfoVisibility:self.infoVisible];
}

// New method to setup the loading indicator and progress label
- (void)setupLoadingIndicator {
    // First, remove any existing indicators to prevent duplicates
    [self removeExistingLoadingIndicators];
    
    // Activity Indicator
    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.hidesWhenStopped = YES;
    self.activityIndicator.center = self.view.center; // Center in the main view initially
    self.activityIndicator.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.activityIndicator.tag = 1001; // Tag for identification
    [self.view addSubview:self.activityIndicator]; // Add to main view, not scroll view

    // Progress Label
    self.progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
    self.progressLabel.center = CGPointMake(self.view.center.x, self.view.center.y + self.activityIndicator.bounds.size.height / 2 + 25); // Position below indicator
    self.progressLabel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.progressLabel.textColor = [UIColor grayColor]; // Changed text color to gray
    self.progressLabel.backgroundColor = [UIColor clearColor]; // Removed background color
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.font = [UIFont systemFontOfSize:14];
    self.progressLabel.layer.cornerRadius = 8.0;
    self.progressLabel.layer.masksToBounds = YES;
    self.progressLabel.hidden = YES; // Initially hidden
    self.progressLabel.tag = 1002; // Tag for identification
    [self.view addSubview:self.progressLabel];
    
    Debug(@"[PhotoContent] Setup new loading indicators for %@", self.seafFile ? self.seafFile.name : @"unknown");
}

// Helper method to remove any existing loading indicators
- (void)removeExistingLoadingIndicators {
    // Remove all activity indicators and progress labels from the view
    for (UIView *subview in self.view.subviews) {
        if ([subview isKindOfClass:[UIActivityIndicatorView class]] ||
            ([subview isKindOfClass:[UILabel class]] &&
             (subview.tag == 1002 || [[(UILabel *)subview text] hasSuffix:@"%"]))) {
            
            Debug(@"[PhotoContent] Removing existing indicator/label: %@", subview);
            [subview removeFromSuperview];
        }
    }
    
    // Clear references
    self.activityIndicator = nil;
    self.progressLabel = nil;
}

// Detect scroll position for info scroll view
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Check if it's the info scroll view
    if (scrollView == self.infoView.infoScrollView) {
        // If at the top and being pulled down, track the dragging progress
        if (scrollView.contentOffset.y < 0) {
            // The more negative the content offset, the more it's being pulled down
            CGFloat pullDistance = -scrollView.contentOffset.y;
            
            // Check if we're actively dragging (not just bouncing back)
            if (scrollView.isDragging) {
                // Get the drag direction using the translation of the pan gesture
                CGPoint translation = [scrollView.panGestureRecognizer translationInView:self.view];
                
                // If pulled down more than a threshold and gesture is moving downward
                if (pullDistance > 40 && translation.y > 0) {
                    if (!self.draggedBeyondTopEdge) {
                        self.draggedBeyondTopEdge = YES;
                        [self notifyGalleryViewControllerToHideInfoPanel];
                    }
                }
            }
        }
    } else if (scrollView == self.scrollView) {
        // This is the main image scroll view
        // Center image in scroll view as user zooms
        [self scrollViewDidZoom:scrollView];
    }
}

// Detect when user finishes dragging the info scroll view down
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    // Check if this is the info scroll view
    if (scrollView == self.infoView.infoScrollView) {
        // If at the top and being pulled down, hide the info panel
        if (scrollView.contentOffset.y <= 0 && [scrollView.panGestureRecognizer translationInView:self.view].y > 10) {
            // Find the gallery view controller and notify it to hide the info panel
            [self notifyGalleryViewControllerToHideInfoPanel];
        }
    }
}

// Track start of drag operation
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView == self.infoView.infoScrollView) {
        // Reset the tracking flag at the start of each drag operation
        self.draggedBeyondTopEdge = NO;
    }
}

// Helper method to notify the gallery view controller to hide the info panel
- (void)notifyGalleryViewControllerToHideInfoPanel {
    UIViewController *parentVC = self.parentViewController;
    while (parentVC && ![parentVC isKindOfClass:[SeafPhotoGalleryViewController class]]) {
        parentVC = parentVC.parentViewController;
    }
    
    if (parentVC) {
        @try {
            // Try to call the handleSwipeDown method on the gallery view controller
            SEL handleSwipeDownSelector = NSSelectorFromString(@"handleSwipeDown:");
            if ([parentVC respondsToSelector:handleSwipeDownSelector]) {
                [parentVC performSelector:handleSwipeDownSelector withObject:nil];
            }
        } @catch (NSException *exception) {
            Debug(@"Exception when trying to call handleSwipeDown: %@", exception);
        }
    }
}

// Add setter for connection property
- (void)setConnection:(SeafConnection *)connection {
    _connection = connection;
}

// Add setter method for seafFile
- (void)setSeafFile:(id<SeafPreView>)seafFile {    // If the same file, ignore
    if (_seafFile == seafFile) {
        return;
    }
    // Update the stored file
    _seafFile = seafFile;
    
    if ([self.seafFile isKindOfClass:[SeafFile class]]) {
        // Store previous loading state to determine if we need to update UI
        BOOL wasLoading = _seafFile && [_seafFile hasCache];
        BOOL willBeLoading = seafFile && ![seafFile hasCache];
        
        SeafFile *f = seafFile;
        Debug(@"[PhotoContent] Setting seafFile: %@, ooid: %@",
              seafFile.name,
              f.ooid ? f.ooid : @"nil (needs download)");
        
        // Update loading indicator based on new file state
        if (wasLoading && !willBeLoading) {
            // File was loading but now has loaded - hide indicator
            Debug(@"[PhotoContent] File now loaded, hiding indicator");
            [self hideLoadingIndicator];
        }
        else if (!wasLoading && willBeLoading) {
            Debug(@"[PhotoContent] New file needs download/processing, showing indicator");
            [self showLoadingIndicator];
        }
    }
    
    // If view is loaded, reload image with the new file
    if (self.isViewLoaded) {
        [self loadImage];
    }
}

// Add cleanup when the view is about to disappear
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    if (self.activityIndicator) {
        Debug(@"[PhotoContent] Cleaning up indicators in viewWillDisappear for %@", self.seafFile ? self.seafFile.name : self.photoURL);
        [self cleanupAllLoadingIndicators];
    }
}

// Method to prepare the view controller for reuse (called from gallery when recycling)
- (void)prepareForReuse {
    Debug(@"[PhotoContent] Preparing for reuse %@", self.seafFile ? self.seafFile.name : @"unknown");
    
    // Remove error view if it exists
    if (self.errorPlaceholderView) {
        [self.errorPlaceholderView removeFromSuperview];
        self.errorPlaceholderView = nil;
    }

    // Cancel any ongoing image loading or download requests
    // Only if the image isn't already loaded
    if (!self.imageView.image || !self.seafFile || ![self.seafFile hasCache]) {
        [self cancelImageLoading];
    }
    
    // Clean up any existing UI elements
    [self cleanupAllLoadingIndicators];
    
    // Reset zoom scale
    if (self.scrollView) {
        self.scrollView.zoomScale = 1.0;
    }
    
    // Reset info view if needed
    if (self.infoVisible) {
        self.infoVisible = NO;
        self.infoView.hidden = YES;
    }
    
    // Reset placeholder/error image flag
    self.isDisplayingPlaceholderOrErrorImage = NO;
    
    Debug(@"[PhotoContent] View controller reset and ready for reuse");
}

// Cancel any ongoing image loading or download requests
- (void)cancelImageLoading {
    Debug(@"[PhotoContent] Canceling image loading for %@", self.seafFile ? self.seafFile.name : @"unknown");
    
    // Don't cancel if the image is already loaded and displayed
    if (self.imageView.image != nil && self.seafFile && [self.seafFile hasCache]) {
        Debug(@"[PhotoContent] Not canceling - image already displayed: %@", self.seafFile.name);
        // Still clean up any loading indicators
        [self cleanupAllLoadingIndicators];
        return;
    }
    // Cancel the SeafFile download task
    if (self.seafFile && [self.seafFile isKindOfClass:[SeafFile class]]) {
        // Cancel file download
        [(SeafFile *)self.seafFile cancelDownload];
        
        // Clean up any ongoing requests or operations
        [self.seafFile setDelegate:nil];
    }
    
    // Clean up loading indicators
    [self cleanupAllLoadingIndicators];
    
    Debug(@"[PhotoContent] Image loading canceled for %@", self.seafFile ? self.seafFile.name : @"unknown");
}

// Release the memory of the loaded image
- (void)releaseImageMemory {
    Debug(@"[PhotoContent] Releasing image memory for %@", self.seafFile ? self.seafFile.name : @"unknown");
    
    // Clear the error placeholder view if it exists
    if (self.errorPlaceholderView) {
        [self.errorPlaceholderView removeFromSuperview];
        self.errorPlaceholderView = nil;
    }

    // Clear the image data to free memory
    if (self.imageView) {
        self.imageView.image = nil;
        // Reset placeholder flag since we're clearing the image
        self.isDisplayingPlaceholderOrErrorImage = NO;
    }
        
    Debug(@"[PhotoContent] Image memory released for %@", self.seafFile ? self.seafFile.name : @"unknown");
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    // Check if we're still part of the UIPageViewController's view controllers array
    UIViewController *parentVC = self.parentViewController;
    if ([parentVC isKindOfClass:[UIPageViewController class]]) {
        UIPageViewController *pageVC = (UIPageViewController *)parentVC;
        NSArray *viewControllers = pageVC.viewControllers;
        
        // Only cancel loading if this VC is no longer in the viewControllers array
        // AND we're at least 2 pages away from current view
        if (![viewControllers containsObject:self]) {
            NSInteger currentIndex = -1;
            NSInteger thisIndex = -1;
            
            // Try to get the photo gallery view controller
            UIViewController *galleryVC = pageVC.parentViewController;
            if ([galleryVC isKindOfClass:[SeafPhotoGalleryViewController class]]) {
                @try {
                    SeafPhotoGalleryViewController *specificGalleryVC = (SeafPhotoGalleryViewController *)galleryVC;
                    // Try to access the current index and the total array of view controllers
                    NSArray<SeafPhotoContentViewController *> *allPhotoVCs = specificGalleryVC.photoViewControllers;
                    NSUInteger currentPhotoIndex = specificGalleryVC.currentIndex;
                    
                    if (allPhotoVCs) { // Current index is always valid if galleryVC exists
                        thisIndex = [allPhotoVCs indexOfObject:self];
                        
                        // Only cancel if we're at least 2 pages away from current
                        if (thisIndex != NSNotFound && abs((int)(thisIndex - currentPhotoIndex)) > 1) {
                            Debug(@"[PhotoContent] View far from current page, canceling loads: %@", self.seafFile.name);
                            [self cancelImageLoading];
                        } else {
                            Debug(@"[PhotoContent] View still near current page, keeping loads: %@", self.seafFile.name);
                        }
                    } else {
                        // Fallback to the old behavior if we can't get index info
                        Debug(@"[PhotoContent] Could not determine page indices, using default behavior for %@", self.seafFile.name);
                        [self cancelImageLoading];
                    }
                } @catch (NSException *exception) {
                    Debug(@"[PhotoContent] Exception when accessing gallery properties: %@", exception);
                    // Fallback to the old behavior
                    [self cancelImageLoading];
                }
            } else {
                // Not in a photo gallery, use old behavior
                Debug(@"[PhotoContent] View disappeared and no longer in page VC: %@", self.seafFile.name);
                [self cancelImageLoading];
            }
        }
    } else {
        // If we're not part of a page view controller at all, we should cancel any downloads
        Debug(@"[PhotoContent] View disappeared: %@", self.seafFile.name);
        [self cancelImageLoading];
    }
}

// Add a new method for preloading images
- (void)preloadImage {
    // Only preload if we have a valid seafFile with an ooid
    if ([self.seafFile isKindOfClass:[SeafFile class]] && self.seafFile && [self.seafFile hasCache]) {
        if (!self.imageView.image) {
            Debug(@"[PhotoContent] Preloading image for %@", self.seafFile.name);
            
            // Load in background without affecting UI
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [(SeafFile *)self.seafFile getImageWithCompletion:^(UIImage *image) { // Assumes getImageWithCompletion exists on id<SeafPreView>
                    if (image) {
                        // Store in memory but don't display yet
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (!self.imageView.image) {
                                self.imageView.image = image;
                                Debug(@"[PhotoContent] Image preloaded for %@", self.seafFile.name);
                            }
                        });
                    }
                }];
            });
        }
    }
}

// Add to viewWillAppear to ensure images are loaded when coming into view
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    UIViewController *parentVC = self.parentViewController;
    while (parentVC && ![parentVC isKindOfClass:[UINavigationController class]]) {
        parentVC = parentVC.parentViewController;
    }

    BOOL shouldBeBlackBackground = NO;
    if ([parentVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navController = (UINavigationController *)parentVC;
        // If the navigation bar is hidden, AND the info view is NOT visible,
        if (navController.navigationBarHidden && !self.infoVisible) {
            shouldBeBlackBackground = YES;
        }
    }

    // Set background color immediately based on inferred state
    if (shouldBeBlackBackground) {
        // Ensure the view is in the 'dark mode' state
        self.view.backgroundColor = [UIColor blackColor];
        self.scrollView.backgroundColor = [UIColor blackColor];
        self.imageView.backgroundColor = [UIColor clearColor]; // Ensure image view is clear over black
    } else {
        // Ensure the view is in the 'light mode' state
        // self.view.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0]; // This is already set in viewDidLoad
        // self.scrollView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0]; // This is already set in setupScrollView
        self.imageView.backgroundColor = [UIColor clearColor]; 
    }
    // When a new view is about to appear during a transition, make sure layout is correct
    [self updateViewFramesForInfoVisibility:self.infoVisible];

    // Update info view if it's supposed to be visible
    if (self.infoVisible) {
        self.infoView.hidden = NO;
        [self updateInfoView];
    }

    // Make sure the image is loaded
    BOOL needsImageLoad = NO;
    
    if (!self.imageView.image) {
        // No image at all
        needsImageLoad = YES;
    } else if (self.isDisplayingPlaceholderOrErrorImage && self.seafFile && [self.seafFile hasCache]) {
        // If currently displaying a placeholder or error image, and seafFile has cache, need to reload
        needsImageLoad = YES;
    }
    
    if (needsImageLoad && self.seafFile) {
        Debug(@"[PhotoContent] Image needs loading in viewWillAppear (placeholder: %@), loading now: %@", 
              self.isDisplayingPlaceholderOrErrorImage ? @"YES" : @"NO", 
              self.seafFile.name);
        // If currently displaying an error, remove it before attempting to load again
        if (self.isDisplayingPlaceholderOrErrorImage && self.errorPlaceholderView) {
            [self.errorPlaceholderView removeFromSuperview];
            self.errorPlaceholderView = nil;
            // self.isDisplayingPlaceholderOrErrorImage = NO; // loadImage will reset this
        }
        [self loadImage];
    }
}

// Helper method to create the EXIF Camera Model row
- (CGFloat)createExifModelRow:(NSString *)cameraModel
                       inView:(UIView *)parentView
                    yPosition:(CGFloat)yPosition
               availableWidth:(CGFloat)availableWidth
                    modelFont:(UIFont *)modelFont
                    textColor:(UIColor *)textColor
                  cardPadding:(CGFloat)cardPadding
{
    if (!cameraModel || cameraModel.length == 0) return 0;

    UILabel *modelLabel = [[UILabel alloc] initWithFrame:CGRectMake(cardPadding, yPosition, availableWidth - 2 * cardPadding, 0)];
    modelLabel.font = modelFont;
    modelLabel.textColor = textColor;
    modelLabel.text = cameraModel;
    [modelLabel sizeToFit]; // Adjust height
    CGRect modelFrame = modelLabel.frame;
    modelFrame.size.width = availableWidth - 2 * cardPadding; // Ensure it takes full width
    modelLabel.frame = modelFrame;
    [parentView addSubview:modelLabel];

    // Return height including bottom padding
    return modelLabel.frame.size.height + cardPadding;
}

// Helper method to create the EXIF Time and Dimensions rows
- (CGFloat)createExifTimeAndDimensionsRows:(NSString *)formattedTime
                                dimensions:(NSString *)dimensionsString
                                    inView:(UIView *)parentView
                                 yPosition:(CGFloat)yPosition
                            availableWidth:(CGFloat)availableWidth
                                mediumFont:(UIFont *)mediumFont
                                 textColor:(UIColor *)textColor
                               cardPadding:(CGFloat)cardPadding
{
    CGFloat currentY = yPosition;
    CGFloat rowHeight = 0;

    // Time Label
    if (formattedTime && ![formattedTime isEqualToString:@"-"]) {
        UILabel *timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(cardPadding, currentY, availableWidth - 2 * cardPadding, 0)];
        timeLabel.font = mediumFont;
        timeLabel.textColor = textColor;
        timeLabel.text = [NSString stringWithFormat:NSLocalizedString(@"Capture Time • %@", @"Seafile"), formattedTime];
        [timeLabel sizeToFit];
        CGRect timeFrame = timeLabel.frame;
        timeFrame.size.width = availableWidth - 2 * cardPadding;
        timeLabel.frame = timeFrame;
        [parentView addSubview:timeLabel];
        currentY += timeLabel.frame.size.height + cardPadding - 2; // Adjust spacing
        rowHeight += timeLabel.frame.size.height + cardPadding - 2;
    }

    // Dimensions Label
    if (dimensionsString && ![dimensionsString isEqualToString:@"-"]) {
        UILabel *dimLabel = [[UILabel alloc] initWithFrame:CGRectMake(cardPadding, currentY, availableWidth - 2 * cardPadding, 0)];
        dimLabel.font = mediumFont;
        dimLabel.textColor = textColor;
        dimLabel.text = [NSString stringWithFormat:NSLocalizedString(@"Dimensions • %@", @"Seafile"), dimensionsString];

        [dimLabel sizeToFit];
        CGRect dimFrame = dimLabel.frame;
        dimFrame.size.width = availableWidth - 2 * cardPadding;
        dimLabel.frame = dimFrame;
        [parentView addSubview:dimLabel];
        rowHeight += dimLabel.frame.size.height;
    }

    return rowHeight;
}

// Update scroll view content size to match image size
- (void)updateScrollViewContentSize {
    if (!self.imageView.image) return;
    
    // When info panel is visible, make sure the image view remains centered in the visible portion
    if (self.infoVisible) {
        // Keep the image view filling the scroll view frame
        self.imageView.frame = self.scrollView.bounds;
        self.scrollView.zoomScale = 1.0;
        
        // Make sure the content is centered in the visible part
        [self scrollViewDidZoom:self.scrollView];
    } else {
        // For normal full-screen mode, just fill the scroll view
        self.imageView.frame = self.scrollView.bounds;
        self.scrollView.zoomScale = 1.0;
    }
}

// Update scroll view zoom scales
- (void)updateZoomScalesForSize:(CGSize)size {
    if (!self.imageView.image) return;
    
    // Reset minimum/maximum zoom levels
    self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.maximumZoomScale = 3.0;
    self.scrollView.zoomScale = 1.0;
    
    // Update image view size
    self.imageView.frame = CGRectMake(0, 0, size.width, size.height);
}

@end
