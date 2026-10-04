import AppIntents
import SwiftUI
import WidgetKit

@main
struct HeadphoneControlsBundle: WidgetBundle {
    var body: some Widget {
        HeadphoneSettingsControl()
        HeadphoneEqualizerControl()
        HeadphoneNoiseControl()
        HeadphoneSpeakToChatControl()
    }
}

struct HeadphoneSpeakToChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "dev.baglayan.Acouplet.speak-to-chat", intent: HeadphoneSpeakToChatConfiguration.self) { configuration in
            ControlWidgetButton(action: SetHeadphoneSpeakToChatIntent(action: configuration.action)) {
                Label(configuration.action?.controlTitle ?? "Speak-to-Chat", systemImage: "person.wave.2")
            }
        }
        .displayName("Speak-to-Chat")
        .description("Turn Speak-to-Chat on or off for your connected Sony headphones.")
        .promptsForUserConfiguration()
    }
}

struct HeadphoneNoiseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "dev.baglayan.Acouplet.noise-control", intent: HeadphoneNoiseControlConfiguration.self) { configuration in
            ControlWidgetButton(action: SetHeadphoneNoiseControlIntent(action: configuration.action)) {
                if let action = configuration.action {
                    Label {
                        Text(action.controlTitle)
                    } icon: {
                        if let symbol = action.symbolName {
                            Image(symbol)
                        } else {
                            Image(systemName: action.systemSymbol)
                        }
                    }
                } else {
                    Label("Noise Control", systemImage: "headphones")
                }
            }
        }
        .displayName("Noise Control")
        .description("Choose a noise-control action for your connected Sony headphones.")
        .promptsForUserConfiguration()
    }
}

struct HeadphoneSettingsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.baglayan.Acouplet.settings") {
            ControlWidgetButton(action: OpenHeadphoneViewIntent(target: .settings)) {
                Label("Headphone Settings", systemImage: "earbuds.stemless")
            }
        }
        .displayName("Headphone Settings")
        .description("Open settings for your Sony headphones.")
    }
}

struct HeadphoneEqualizerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.baglayan.Acouplet.equalizer") {
            ControlWidgetButton(action: OpenHeadphoneViewIntent(target: .equalizer)) {
                Label("Equalizer", systemImage: "slider.vertical.3")
            }
        }
        .displayName("Equalizer")
        .description("Open your headphone equalizer and saved presets.")
    }
}
