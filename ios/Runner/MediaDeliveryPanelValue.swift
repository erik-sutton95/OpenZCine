import MonitorPresentation

/// Projects source-owned export choices without changing their defaults or saved identifiers.
enum MediaDeliveryPanelValue {
    static func export(
        configuration: MediaDeliveryConfiguration,
        lutAvailable: Bool,
        lutLabel: String,
        filename: String?,
        destination: MediaDeliveryDestination?
    ) -> MonitorMediaDeliveryValue.Export {
        .init(
            filename: filename,
            bakeLUT: .init(
                "Bake LUT",
                help: lutAvailable
                    ? "Apply \(lutLabel) to exports."
                    : "No LUT selected - pick one in view assists.",
                isOn: configuration.bakeLUT,
                enabled: lutAvailable
            ),
            format: destination == .nativeShare
                ? .init(
                    "Format",
                    help:
                        "Export container for shared clips - MOV preserves quality; MP4 is more widely compatible.",
                    options: MediaExportFormat.allCases.map {
                        .init(id: $0.rawValue, label: $0.label)
                    },
                    selectedID: configuration.exportFormat.rawValue
                ) : nil,
            includeMetadata: .init(
                "Include metadata",
                help: "Filename, capture date, and size (best-effort JSON sidecar).",
                isOn: configuration.includeMetadata
            ),
            reupload: destination == .frameio
                ? .init(
                    "Re-upload already uploaded",
                    help: "Skip clips already on Frame.io unless enabled.",
                    isOn: configuration.forceFrameioReupload
                ) : nil
        )
    }

    static func postExport(
        _ action: MediaDeliveryPostExportAction
    ) -> MonitorMediaDeliveryValue.Choices {
        .init(
            "",
            options: [
                .init(id: "systemShare", label: "Share"),
                .init(id: "saveToPhotos", label: "Save to Photos"),
            ],
            selectedID: action == .systemShare ? "systemShare" : "saveToPhotos"
        )
    }
}

extension MediaDeliveryOverlayState {
    /// Photos access and ingest can show a spinner alongside the existing determinate bar.
    var monitorProgressValue: MonitorMediaDeliveryProgressValue {
        .init(
            status: statusLine,
            batch: batchLine,
            fraction: overallFraction,
            preparing: showsBusySpinner,
            showsProgress: !isPreparingClip
        )
    }
}
