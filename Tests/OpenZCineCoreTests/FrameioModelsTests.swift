import Foundation
import Testing

@testable import OpenZCineCore

@Test func createFileResponseExtractsIDAndUploadURLs() throws {
    let json = """
        { "data": {
            "id": "fa18ba7b-b3ee-4dd6-9b31-bd07e554241d",
            "name": "my_file.mov",
            "status": "created",
            "media_type": "video/quicktime",
            "upload_urls": [
                { "size": 16881997, "url": "https://s3.example/part1" },
                { "size": 16881996, "url": "https://s3.example/part2" }
            ]
        } }
        """
    let response = try FrameioJSON.decode(FrameioCreateFileResponse.self, from: Data(json.utf8))
    #expect(response.fileID == "fa18ba7b-b3ee-4dd6-9b31-bd07e554241d")
    #expect(response.mediaType == "video/quicktime")
    #expect(response.uploadURLs.count == 2)
    #expect(response.uploadURLs.first?.absoluteString == "https://s3.example/part1")
}

@Test func createFileResponseRejectsStringUploadURLs() {
    let json = """
        { "data": { "id": "file-123",
            "upload_urls": ["https://s3.example/part1"] } }
        """
    #expect(throws: FrameioDecodingError.self) {
        try FrameioJSON.decode(FrameioCreateFileResponse.self, from: Data(json.utf8))
    }
}

@Test func uploadModelsRedactPresignedURLFromDiagnosticDescriptions() throws {
    let signedURL = "https://s3.example/upload?X-Amz-Signature=unit-signature"
    let json = """
        { "data": { "id": "file-123", "upload_urls": [
            { "size": 4, "url": "\(signedURL)" }
        ] } }
        """
    let response = try FrameioJSON.decode(FrameioCreateFileResponse.self, from: Data(json.utf8))
    let descriptions = [
        String(describing: response.uploadParts[0]),
        String(reflecting: response.uploadParts[0]),
        String(describing: response.data),
        String(reflecting: response.data),
        String(describing: response),
        String(reflecting: response),
    ]

    for description in descriptions {
        #expect(!description.contains(signedURL))
    }
}

@Test func decodingErrorRedactsResponseBody() {
    let json = #"{"data":{"id":"x","upload_urls":["not-an-object"]}}"#
    do {
        _ = try FrameioJSON.decode(FrameioCreateFileResponse.self, from: Data(json.utf8))
        Issue.record("expected decode to throw")
    } catch let error as FrameioDecodingError {
        #expect(error.responseByteCount > 0)
        #expect(error.errorDescription?.contains("upload_urls") == false)
        #expect(String(describing: error).contains("upload_urls") == false)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func projectListDecodesFromDataEnvelope() throws {
    let json = """
        { "data": [ { "id": "p1", "name": "My Project", "root_folder_id": "f1" } ] }
        """
    let list = try FrameioJSON.decode(FrameioList<FrameioProject>.self, from: Data(json.utf8))
    #expect(list.data.first?.id == "p1")
    #expect(list.data.first?.name == "My Project")
    #expect(list.data.first?.rootFolderID == "f1")
}

@Test func workspaceListDecodesFromDataEnvelope() throws {
    let json = """
        { "data": [ { "id": "w1", "name": "Production" } ] }
        """
    let list = try FrameioJSON.decode(FrameioList<FrameioWorkspace>.self, from: Data(json.utf8))
    #expect(list.data.first?.id == "w1")
    #expect(list.data.first?.name == "Production")
}

@Test func createFileRequestEncodesSnakeCaseEnvelope() throws {
    let request = FrameioCreateFileRequest(name: "C0001_LUT.mov", fileSize: 1234)
    let data = try JSONEncoder().encode(request)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"file_size\":1234"))
    #expect(json.contains("\"name\":\"C0001_LUT.mov\""))
    #expect(json.contains("\"data\""))
    #expect(!json.contains("media_type"))
}

@Test func fileUploadStatusDecodesUploadComplete() throws {
    let json = """
        { "data": {
            "id": "fa18ba7b-b3ee-4dd6-9b31-bd07e554241d",
            "upload_complete": true
        } }
        """
    let status = try FrameioJSON.decode(FrameioFileUploadStatus.self, from: Data(json.utf8))
    #expect(status.fileID == "fa18ba7b-b3ee-4dd6-9b31-bd07e554241d")
    #expect(status.uploadComplete)
}

@Test func mediaTypeForFilenameUsesExtension() {
    #expect(FrameioMediaType.forFilename("clip.MP4") == "video/mp4")
    #expect(FrameioMediaType.forFilename("clip_LUT.mov") == "video/quicktime")
}

@Test func createProjectRequestEncodesDataEnvelope() throws {
    let request = FrameioCreateProjectRequest(name: "Dailies")
    let data = try JSONEncoder().encode(request)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"name\":\"Dailies\""))
    #expect(json.contains("\"data\""))
}

@Test func createProjectResponseDecodesFromDataEnvelope() throws {
    let json = """
        { "data": {
            "id": "p-new",
            "name": "Dailies",
            "root_folder_id": "f-root"
        } }
        """
    let project = try FrameioJSON.decode(FrameioOne<FrameioProject>.self, from: Data(json.utf8))
        .data
    #expect(project.id == "p-new")
    #expect(project.name == "Dailies")
    #expect(project.rootFolderID == "f-root")
}
