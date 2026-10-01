// ato.m - visual-only Subtransit Drive ATO prototype for macOS.
// No game memory, process injection, or non-visual telemetry is used.

#import <AppKit/AppKit.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Import ScreenCaptureKit for macOS 13+
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 130000
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

static volatile BOOL gATOEnabled = NO;
static volatile BOOL gQuit = NO;
static id gMonitor = nil;

// Keyboard mapping supplied by the user. T3/T4 are intentionally unused.
typedef enum { GEAR_T1, GEAR_T2, GEAR_NEUTRAL, GEAR_B1, GEAR_B2, GEAR_B3, GEAR_REVERSE, GEAR_FORWARD } Gear;

static void keyDown(NSString *key) {
    CGKeyCode code = 0;
    NSDictionary *codes = @{@"0":@29,@"1":@18,@"2":@19,@"5":@23,@"6":@22,@"7":@26,@"8":@28,@"9":@25,
                            @"I":@34,@"V":@9,@"A":@0,@"D":@2,@"E":@14};
    NSNumber *n = codes[key.uppercaseString];
    if (!n) return;
    code = n.unsignedShortValue;
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, code, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, code, false);
    CGEventPost(kCGHIDEventTap, down); CGEventPost(kCGHIDEventTap, up);
    CFRelease(down); CFRelease(up);
}

static void applyGear(Gear gear) {
    // Avoid repeated key presses: the game treats these as controller commands.
    static Gear last = -1;
    if (gear == last) return;
    last = gear;
    switch (gear) {
        case GEAR_T1: keyDown(@"1"); break;
        case GEAR_T2: keyDown(@"2"); break;
        case GEAR_NEUTRAL: keyDown(@"5"); break;
        case GEAR_B1: keyDown(@"6"); break;
        case GEAR_B2: keyDown(@"7"); break;
        case GEAR_B3: keyDown(@"8"); break;
        default: break;
    }
}

static CGImageRef screenshotWithSCK(void) {
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 130000
    @autoreleasepool {
        NSError *error = nil;
        SCDisplay *display = [SCShareableContent excludingDesktopWindows:NO executionQueue:dispatch_get_main_queue()].displays.firstObject;
        if (!display) return NULL;
        
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.sourceResolution = YES;
        
        SCScreenshotContentFilter *scFilter = [[SCScreenshotContentFilter alloc] initWithDisplay:display];
        
        CGImageRef __block result = NULL;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        
        [SCScreenshotManager captureImageWithContentFilter:scFilter
                                             configuration:config
                                          completionHandler:^(CGImageRef image, NSError *error) {
            if (image) result = CGImageRetain(image);
            dispatch_semaphore_signal(sem);
        }];
        
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        return result;
    }
#else
    return NULL;
#endif
}

static CGImageRef screenshot(void) {
    return screenshotWithSCK();
}

static NSString *ocr(CGImageRef image) {
    if (!image) return @"";
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = NO;
    request.minimumTextHeight = 0.008;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error = nil;
    [handler performRequests:@[request] error:&error];
    if (error) return @"";
    NSMutableString *result = [NSMutableString string];
    for (VNRecognizedTextObservation *observation in request.results) {
        VNRecognizedText *candidate = [[observation topCandidates:1] firstObject];
        if (candidate) [result appendFormat:@"%@\n", candidate.string];
    }
    return result;
}

static double numberAfter(NSString *text, NSString *label, double fallback) {
    NSRange r = [text rangeOfString:label options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return fallback;
    NSString *tail = [text substringFromIndex:NSMaxRange(r)];
    NSScanner *scanner = [NSScanner scannerWithString:tail];
    double value = fallback;
    return [scanner scanDouble:&value] ? value : fallback;
}

static BOOL containsAny(NSString *text, NSArray<NSString *> *words) {
    for (NSString *word in words)
        if ([text rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static void controllerStep(void) {
    CGImageRef image = screenshot();
    NSString *screen = ocr(image);
    if (image) CGImageRelease(image);
    if (!gATOEnabled) return;

    // Require a positive closed-door indication. Unknown or open is never safe to depart.
    BOOL doorsClosed = containsAny(screen, @[@"DOORS CLOSED", @"DOORS\nCLOSED", @"CLOSED"])
                       && !containsAny(screen, @[@"DOORS OPEN", @"DOORS\nOPEN", @"OPENED"]);
    if (!doorsClosed) {
        applyGear(GEAR_NEUTRAL);
        fprintf(stderr, "ATO held: doors not positively confirmed closed\n");
        return;
    }

    // OCR labels vary by resolution. Only act when values are found; unknown means neutral.
    double speed = numberAfter(screen, @"Current Speed", NAN);
    if (isnan(speed)) speed = numberAfter(screen, @"Speed", NAN);
    double limit = numberAfter(screen, @"Limit", NAN);
    double distance = numberAfter(screen, @"Distance", NAN);

    // Stop at a station: use brake, then neutral. Never attempt a blind departure.
    if (containsAny(screen, @[@"STOP IN 00:00", @"ARRIVED", @"AT STATION"])) {
        applyGear(GEAR_B1);
        return;
    }

    // Conservative speed protection. The limit is read from the current HUD frame.
    if (!isnan(speed) && !isnan(limit) && speed >= limit) {
        applyGear(GEAR_B1);
        return;
    }

    // Announcement at approximately 120 m. One-shot behavior is reset after a station stop.
    static BOOL announced = NO;
    if (!isnan(distance) && distance <= 120.0 && distance > 0.0 && !announced) {
        keyDown(@"I"); announced = YES;
    }
    if (!isnan(distance) && distance > 300.0) announced = NO;

    // Departure profile requested by the user: T2, T1 near 68, neutral near 77.
    if (!isnan(speed)) {
        if (speed < 68.0) applyGear(GEAR_T2);
        else if (speed < 77.0) applyGear(GEAR_T1);
        else applyGear(GEAR_NEUTRAL);
    } else {
        applyGear(GEAR_NEUTRAL);
    }
}

static void installHotkeys(void) {
    NSEventMask mask = NSEventMaskKeyDown;
    gMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
        NSEventModifierFlags f = event.modifierFlags;
        BOOL command = (f & NSEventModifierFlagCommand) != 0;
        BOOL shift = (f & NSEventModifierFlagShift) != 0;
        NSString *key = event.charactersIgnoringModifiers.uppercaseString;
        if (!(command && shift)) return;
        if ([key isEqualToString:@"D"]) { gATOEnabled = YES; fprintf(stderr, "ATO enabled (door check still required)\n"); }
        else if ([key isEqualToString:@"E"]) { gATOEnabled = NO; fprintf(stderr, "ATO paused\n"); }
        else if ([key isEqualToString:@"Q"]) { gQuit = YES; }
    }];
}

int main(void) {
    @autoreleasepool {
        fprintf(stderr, "Visual ATO ready. Cmd-Shift-D enable, Cmd-Shift-E pause, Cmd-Shift-Q quit.\n");
        installHotkeys();
        while (!gQuit) {
            @autoreleasepool { controllerStep(); }
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.20]];
        }
        if (gMonitor) [NSEvent removeMonitor:gMonitor];
        applyGear(GEAR_NEUTRAL);
    }
    return 0;
}
