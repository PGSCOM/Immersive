/// macOS menu-bar item (NSStatusItem). AppKit lives on the main thread, so
/// it is driven from the host's main loop through Tray::pump().

#include "ui/host_ui.h"

#import <Cocoa/Cocoa.h>

@interface Im2TrayTarget : NSObject
@property(nonatomic, assign) immersive::ui::TrayModel* model;
@end

@implementation Im2TrayTarget
- (void)openPanel:(id)sender {
    (void)sender;
    self.model->open();
}
- (void)quitHost:(id)sender {
    (void)sender;
    self.model->quit();
}
@end

namespace immersive::ui {

namespace {

/// The mark as a template image: macOS tints it for the light/dark menu bar.
NSImage* mark_image() {
    const int px = 36;  // 18 pt at 2x
    const auto pixels = tray_icon_pixels(px, 0xFF000000, false);
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:nullptr
                      pixelsWide:px
                      pixelsHigh:px
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:px * 4
                    bitsPerPixel:32];
    unsigned char* data = [rep bitmapData];
    for (size_t i = 0; i < pixels.size(); ++i) {  // premultiplied RGBA; ink is black
        data[i * 4 + 0] = 0;
        data[i * 4 + 1] = 0;
        data[i * 4 + 2] = 0;
        data[i * 4 + 3] = static_cast<unsigned char>(pixels[i] >> 24);
    }
    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [image addRepresentation:rep];
    [image setTemplate:YES];
    return image;
}

class MacTray : public Tray {
public:
    explicit MacTray(TrayModel model) : m_(std::move(model)) {
        [NSApplication sharedApplication];
        // No Dock icon, no menu bar of our own: just the status item.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        target_ = [[Im2TrayTarget alloc] init];
        target_.model = &m_;

        item_ = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
        item_.button.image = mark_image();
        item_.button.toolTip = @"Immersive-2";

        menu_ = [[NSMenu alloc] init];
        menu_.autoenablesItems = NO;
        NSMenuItem* open = [menu_ addItemWithTitle:@"Open Immersive-2" action:@selector(openPanel:) keyEquivalent:@""];
        open.target = target_;
        [menu_ addItem:[NSMenuItem separatorItem]];
        status_ = [menu_ addItemWithTitle:@"" action:nil keyEquivalent:@""];
        status_.enabled = NO;
        pin_ = [menu_ addItemWithTitle:@"" action:nil keyEquivalent:@""];
        pin_.enabled = NO;
        [menu_ addItem:[NSMenuItem separatorItem]];
        NSMenuItem* quit = [menu_ addItemWithTitle:@"Quit" action:@selector(quitHost:) keyEquivalent:@"q"];
        quit.target = target_;
        item_.menu = menu_;
        refresh();
    }

    ~MacTray() override {
        [[NSStatusBar systemStatusBar] removeStatusItem:item_];
    }

    bool visible() const override { return item_ != nil; }

    void pump(std::chrono::milliseconds wait) override {
        @autoreleasepool {
            NSDate* until = [NSDate dateWithTimeIntervalSinceNow:wait.count() / 1000.0];
            NSEvent* e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until
                                               inMode:NSDefaultRunLoopMode dequeue:YES];
            while (e) {
                [NSApp sendEvent:e];
                e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
                                          inMode:NSDefaultRunLoopMode dequeue:YES];
            }
            if (std::chrono::steady_clock::now() >= next_refresh_) refresh();
        }
    }

private:
    void refresh() {
        next_refresh_ = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        status_.title = [NSString stringWithUTF8String:m_.status().c_str()] ?: @"";
        pin_.title = [NSString stringWithUTF8String:m_.pin_line().c_str()] ?: @"";
        item_.button.toolTip = [@"Immersive-2: " stringByAppendingString:status_.title];
    }

    TrayModel m_;
    Im2TrayTarget* target_ = nil;
    NSStatusItem* item_ = nil;
    NSMenu* menu_ = nil;
    NSMenuItem* status_ = nil;
    NSMenuItem* pin_ = nil;
    std::chrono::steady_clock::time_point next_refresh_{};
};

}  // namespace

std::unique_ptr<Tray> create_tray(TrayModel model) {
    return std::make_unique<MacTray>(std::move(model));
}

}  // namespace immersive::ui
