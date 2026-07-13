import Foundation

/// Pure on/off semantics for the live-monitor and playback view-assist tools.
public enum AssistToolActivation {
    public static func set(
        _ tool: MonitorAssistTool,
        visible: Bool,
        context: ViewAssistContext,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        switch context {
        case .liveView:
            if visible {
                preferences.liveViewVisibleAssistTools.insert(tool)
            } else {
                preferences.liveViewVisibleAssistTools.remove(tool)
            }
            if MonitorAssistTool.scopeTools.contains(tool) {
                preferences.scopeActivationOrder.removeAll { $0 == tool }
                if visible {
                    preferences.scopeActivationOrder.append(tool)
                }
            }
        case .playback:
            if visible {
                preferences.playbackVisibleAssistTools.insert(tool)
            } else {
                preferences.playbackVisibleAssistTools.remove(tool)
            }
        }
        syncOverlayEnabledFlags(preferences: preferences, configuration: &configuration)
    }

    public static func set(
        _ tool: MonitorAssistTool,
        visible: Bool,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        set(
            tool, visible: visible, context: .liveView, preferences: &preferences,
            configuration: &configuration)
    }

    public static func toggle(
        _ tool: MonitorAssistTool,
        context: ViewAssistContext,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        let isOn = preferences.visibleAssistTools(for: context).contains(tool)
        set(
            tool, visible: !isOn, context: context, preferences: &preferences,
            configuration: &configuration)
    }

    public static func toggle(
        _ tool: MonitorAssistTool,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        toggle(tool, context: .liveView, preferences: &preferences, configuration: &configuration)
    }

    private static func syncOverlayEnabledFlags(
        preferences: OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        configuration.level.enabled =
            preferences.liveViewVisibleAssistTools.contains(.level)
            || preferences.playbackVisibleAssistTools.contains(.level)
        configuration.desqueeze.enabled =
            preferences.liveViewVisibleAssistTools.contains(.desqueeze)
            || preferences.playbackVisibleAssistTools.contains(.desqueeze)
    }
}
