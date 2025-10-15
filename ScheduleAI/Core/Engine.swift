//
//  Engine.swift
//  ScheduleAI
//
//  Created by Tai Wong on 10/1/25.
//

import Foundation
import Folio
import Combine
import CryptoKit
import OSLog

public class Engine: ObservableObject {
    
    public let folio: FolioEngine
    private var ingestConfig: FolioConfig

    public init(folio: FolioEngine) {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        let folioDir = appSupport.appendingPathComponent("Folio", isDirectory: true)
        let docsDir = appSupport.appendingPathComponent("Docs", isDirectory: true)
        
        try? fileManager.createDirectory(at: folioDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: docsDir, withIntermediateDirectories: true)
        
        let dbURL = folioDir.appendingPathComponent("folio.sqlite")
        
        let pdfLoader = PDFDocumentLoader()
        let textLoader = TextDocumentLoader()
        let chunker = UniversalChunker()
        
        do {
            self.folio = try FolioEngine(databaseURL: dbURL, loaders: [pdfLoader, textLoader], chunker: chunker, embedder: nil)
        } catch {
            fatalError("Failed to initialize FolioEngine: \(error)")
        }
        
        var config = FolioConfig()
        
        config.indexing.useFoundationModelPrefixes()
        config.chunking.maxTokensPerChunk = 1000
        config.chunking.overlapTokens = 150
        
        self.ingestConfig = config
        
        
        
    }
}
