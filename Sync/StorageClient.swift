/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Alamofire
import Shared
import Account
import XCGLogger
import Deferred

private let log = Logger.syncLogger


// Not an error that indicates a server problem, but merely an
// error that encloses a StorageResponse.
public class StorageResponseError<T>: MaybeErrorType {
    public let response: StorageResponse<T>

    public init(_ response: StorageResponse<T>) {
        self.response = response
    }

    public var description: String {
        return "Error."
    }
}

public class RequestError: MaybeErrorType {
    public var description: String {
        return "Request error."
    }
}

public class BadRequestError<T>: StorageResponseError<T> {
    public let request: NSURLRequest?

    public init(request: NSURLRequest?, response: StorageResponse<T>) {
        self.request = request
        super.init(response)
    }

    override public var description: String {
        return "Bad request."
    }
}

public class ServerError<T>: StorageResponseError<T> {
    override public var description: String {
        return "Server error."
    }

    override public init(_ response: StorageResponse<T>) {
        super.init(response)
    }
}

public class NotFound<T>: StorageResponseError<T> {
    override public var description: String {
        return "Not found. (\(T.self))"
    }

    override public init(_ response: StorageResponse<T>) {
        super.init(response)
    }
}

public class RecordParseError: MaybeErrorType {
    public var description: String {
        return "Failed to parse record."
    }
}

public class MalformedMetaGlobalError: MaybeErrorType {
    public var description: String {
        return "Supplied meta/global for upload did not serialize to valid JSON."
    }
}

public class RecordTooLargeError: MaybeErrorType {
    public let guid: GUID
    public let size: ByteCount

    public init(size: ByteCount, guid: GUID) {
        self.size = size
        self.guid = guid
    }

    public var description: String {
        return "Record \(self.guid) too large: \(size) bytes."
    }
}

public class BatchingNotSupported: MaybeErrorType {
    public var description: String {
        return "Sync server does not support batching."
    }
}

/**
 * Raised when the storage client is refusing to make a request due to a known
 * server backoff.
 * If you want to bypass this, remove the backoff from the BackoffStorage that
 * the storage client is using.
 */
public class ServerInBackoffError: MaybeErrorType {
    private let until: Timestamp

    public var description: String {
        let formatter = NSDateFormatter()
        formatter.dateStyle = NSDateFormatterStyle.ShortStyle
        formatter.timeStyle = NSDateFormatterStyle.MediumStyle
        let s = formatter.stringFromDate(NSDate.fromTimestamp(self.until))
        return "Server in backoff until \(s)."
    }

    public init(until: Timestamp) {
        self.until = until
    }
}

// Returns milliseconds. Handles decimals.
private func optionalSecondsHeader(input: AnyObject?) -> Timestamp? {
    if input == nil {
        return nil
    }

    if let val = input as? String {
        if let timestamp = decimalSecondsStringToTimestamp(val) {
            return timestamp
        }
    }

    if let seconds: Double = input as? Double {
        // Oh for a BigDecimal library.
        return Timestamp(seconds * 1000)
    }

    if let seconds: NSNumber = input as? NSNumber {
        // Who knows.
        return seconds.unsignedLongLongValue * 1000
    }

    return nil
}

private func optionalIntegerHeader(input: AnyObject?) -> Int64? {
    if input == nil {
        return nil
    }

    if let val = input as? String {
        return NSScanner(string: val).scanLongLong()
    }

    if let val: Double = input as? Double {
        // Oh for a BigDecimal library.
        return Int64(val)
    }

    if let val: NSNumber = input as? NSNumber {
        // Who knows.
        return val.longLongValue
    }

    return nil
}

private func optionalUIntegerHeader(input: AnyObject?) -> Timestamp? {
    if input == nil {
        return nil
    }

    if let val = input as? String {
        return NSScanner(string: val).scanUnsignedLongLong()
    }

    if let val: Double = input as? Double {
        // Oh for a BigDecimal library.
        return Timestamp(val)
    }

    if let val: NSNumber = input as? NSNumber {
        // Who knows.
        return val.unsignedLongLongValue
    }

    return nil
}

public enum SortOption: String {
    case NewestFirst = "newest"
    case OldestFirst = "oldest"
    case Index = "index"
}

public struct ResponseMetadata {
    public let status: Int
    public let alert: String?
    public let nextOffset: String?
    public let records: UInt64?
    public let quotaRemaining: Int64?
    public let timestampMilliseconds: Timestamp         // Non-optional. Server timestamp when handling request.
    public let lastModifiedMilliseconds: Timestamp?     // Included for all success responses. Collection or record timestamp.
    public let backoffMilliseconds: UInt64?
    public let retryAfterMilliseconds: UInt64?

    public init(response: NSHTTPURLResponse) {
        self.init(status: response.statusCode, headers: response.allHeaderFields)
    }

    init(status: Int, headers: [NSObject : AnyObject]) {
        self.status = status
        alert = headers["X-Weave-Alert"] as? String
        nextOffset = headers["X-Weave-Next-Offset"] as? String
        records = optionalUIntegerHeader(headers["X-Weave-Records"])
        quotaRemaining = optionalIntegerHeader(headers["X-Weave-Quota-Remaining"])
        timestampMilliseconds = optionalSecondsHeader(headers["X-Weave-Timestamp"]) ?? 0
        lastModifiedMilliseconds = optionalSecondsHeader(headers["X-Last-Modified"])
        backoffMilliseconds = optionalSecondsHeader(headers["X-Weave-Backoff"]) ??
                              optionalSecondsHeader(headers["X-Backoff"])
        retryAfterMilliseconds = optionalSecondsHeader(headers["Retry-After"])
    }
}

public struct StorageResponse<T> {
    public let value: T
    public let metadata: ResponseMetadata

    init(value: T, metadata: ResponseMetadata) {
        self.value = value
        self.metadata = metadata
    }

    init(value: T, response: NSHTTPURLResponse) {
        self.value = value
        self.metadata = ResponseMetadata(response: response)
    }
}

public typealias BatchToken = String

public struct POSTResult {
    public let modified: Timestamp
    public let success: [GUID]
    public let failed: [GUID: String]
    public let batchToken: BatchToken?

    public static func fromJSON(json: JSON) -> POSTResult? {
        if json.isError {
            return nil
        }

        let batchToken = json["batch"].asString

        if let mDecimalSeconds = json["modified"].asDouble,
           let s = json["success"].asArray,
           let f = json["failed"].asDictionary {
            var failed = false
            let asStringOrFail: JSON -> String = { $0.asString ?? { failed = true; return "" }() }

            // That's the basic structure. Now let's transform the contents.
            let successGUIDs = s.map(asStringOrFail)
            if failed {
                return nil
            }
            let failedGUIDs = mapValues(f, f: asStringOrFail)
            if failed {
                return nil
            }
            let msec = Timestamp(1000 * mDecimalSeconds)
            return POSTResult(modified: msec, success: successGUIDs, failed: failedGUIDs, batchToken: batchToken)
        }
        return nil
    }
}

public typealias Authorizer = (NSMutableURLRequest) -> NSMutableURLRequest
public typealias ResponseHandler = (NSURLRequest?, NSHTTPURLResponse?, Result<AnyObject>) -> Void

// TODO: don't be so naïve. Use a combination of uptime and wall clock time.
public protocol BackoffStorage {
    var serverBackoffUntilLocalTimestamp: Timestamp? { get set }
    func clearServerBackoff()
    func isInBackoff(now: Timestamp) -> Timestamp?   // Returns 'until' for convenience.
}

// Don't forget to batch downloads.
public class Sync15StorageClient {
    private let authorizer: Authorizer
    private let serverURI: NSURL

    public static let maxRecordSizeBytes: Int = 262_140       // A shade under 256KB.
    public static let maxPayloadSizeBytes: Int = 1_000_000    // A shade under 1MB.
    public static let maxPayloadItemCount: Int = 100          // Bug 1250747 will raise this.

    var backoff: BackoffStorage

    let workQueue: dispatch_queue_t
    let resultQueue: dispatch_queue_t

    public init(token: TokenServerToken, workQueue: dispatch_queue_t, resultQueue: dispatch_queue_t, backoff: BackoffStorage) {
        self.workQueue = workQueue
        self.resultQueue = resultQueue
        self.backoff = backoff

        // This is a potentially dangerous assumption, but failable initializers up the stack are a giant pain.
        // We want the serverURI to *not* have a trailing slash: to efficiently wipe a user's storage, we delete
        // the user root (like /1.5/1234567) and not an "empty collection" (like /1.5/1234567/); the storage
        // server treats the first like a DROP table and the latter like a DELETE *, and the former is more
        // efficient than the latter.
        self.serverURI = NSURL(string: token.api_endpoint.endsWith("/")
            ? token.api_endpoint.substringToIndex(token.api_endpoint.endIndex.predecessor())
            : token.api_endpoint)!
        self.authorizer = {
            (r: NSMutableURLRequest) -> NSMutableURLRequest in
            let helper = HawkHelper(id: token.id, key: token.key.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!)
            r.setValue(helper.getAuthorizationValueFor(r), forHTTPHeaderField: "Authorization")
            return r
        }
    }

    public init(serverURI: NSURL, authorizer: Authorizer, workQueue: dispatch_queue_t, resultQueue: dispatch_queue_t, backoff: BackoffStorage) {
        self.serverURI = serverURI
        self.authorizer = authorizer
        self.workQueue = workQueue
        self.resultQueue = resultQueue
        self.backoff = backoff
    }

    func updateBackoffFromResponse<T>(response: StorageResponse<T>) {
        // N.B., we would not have made this request if a backoff were set, so
        // we can safely avoid doing the write if there's no backoff in the
        // response.
        // This logic will have to change if we ever invalidate that assumption.
        if let ms = response.metadata.backoffMilliseconds ?? response.metadata.retryAfterMilliseconds {
            log.info("Backing off for \(ms)ms.")
            self.backoff.serverBackoffUntilLocalTimestamp = ms + NSDate.now()
        }
    }

    func errorWrap<T>(deferred: Deferred<Maybe<T>>, handler: ResponseHandler) -> ResponseHandler {
        return { (request, response, result) in
            log.verbose("Response is \(response).")

            /**
             * Returns true if handled.
             */
            func failFromResponse(response: NSHTTPURLResponse?) -> Bool {
                guard let response = response else {
                    // TODO: better error.
                    log.error("No response")
                    let result = Maybe<T>(failure: RecordParseError())
                    deferred.fill(result)
                    return true
                }

                log.debug("Status code: \(response.statusCode).")

                let storageResponse = StorageResponse(value: response, metadata: ResponseMetadata(response: response))

                self.updateBackoffFromResponse(storageResponse)

                if response.statusCode >= 500 {
                    log.debug("ServerError.")
                    let result = Maybe<T>(failure: ServerError(storageResponse))
                    deferred.fill(result)
                    return true
                }

                if response.statusCode == 404 {
                    log.debug("NotFound<\(T.self)>.")
                    let result = Maybe<T>(failure: NotFound(storageResponse))
                    deferred.fill(result)
                    return true
                }

                if response.statusCode >= 400 {
                    log.debug("BadRequestError.")
                    let result = Maybe<T>(failure: BadRequestError(request: request, response: storageResponse))
                    deferred.fill(result)
                    return true
                }

                return false
            }

            // Check for an error from the request processor.
            if result.isFailure {
                log.error("Response: \(response?.statusCode ?? 0). Got error \(result.error).")

                // If we got one, we don't want to hit the response nil case above and
                // return a RecordParseError, because a RequestError is more fitting.
                if let response = response {
                    if failFromResponse(response) {
                        log.error("This was a failure response. Filled specific error type.")
                        return
                    }
                }

                log.error("Filling generic RequestError.")
                deferred.fill(Maybe<T>(failure: RequestError()))
                return
            }

            if failFromResponse(response) {
                return
            }

            handler(request, response, result)
        }
    }

    lazy private var alamofire: Alamofire.Manager = {
        let ua = UserAgent.syncUserAgent
        let configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration()
        return Alamofire.Manager.managerWithUserAgent(ua, configuration: configuration)
    }()

    func requestGET(url: NSURL) -> Request {
        let req = NSMutableURLRequest(URL: url)
        req.HTTPMethod = Method.GET.rawValue
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let authorized: NSMutableURLRequest = self.authorizer(req)
        return alamofire.request(authorized)
                        .validate(contentType: ["application/json"])
    }

    func requestDELETE(url: NSURL) -> Request {
        let req = NSMutableURLRequest(URL: url)
        req.HTTPMethod = Method.DELETE.rawValue
        req.setValue("1", forHTTPHeaderField: "X-Confirm-Delete")
        let authorized: NSMutableURLRequest = self.authorizer(req)
        return alamofire.request(authorized)
    }

    func requestWrite(url: NSURL, method: String, body: String, contentType: String, ifUnmodifiedSince: Timestamp?) -> Request {
        let req = NSMutableURLRequest(URL: url)
        req.HTTPMethod = method

        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let authorized: NSMutableURLRequest = self.authorizer(req)

        if let ifUnmodifiedSince = ifUnmodifiedSince {
            req.setValue(millisecondsToDecimalSeconds(ifUnmodifiedSince), forHTTPHeaderField: "X-If-Unmodified-Since")
        }

        req.HTTPBody = body.dataUsingEncoding(NSUTF8StringEncoding)!
        return alamofire.request(authorized)
    }

    func requestPUT(url: NSURL, body: JSON, ifUnmodifiedSince: Timestamp?) -> Request {
        return self.requestWrite(url, method: Method.PUT.rawValue, body: body.toString(false), contentType: "application/json;charset=utf-8", ifUnmodifiedSince: ifUnmodifiedSince)
    }

    func requestPOST(url: NSURL, body: JSON, ifUnmodifiedSince: Timestamp?) -> Request {
        return self.requestWrite(url, method: Method.POST.rawValue, body: body.toString(false), contentType: "application/json;charset=utf-8", ifUnmodifiedSince: ifUnmodifiedSince)
    }

    func requestPOST(url: NSURL, body: [String], ifUnmodifiedSince: Timestamp?) -> Request {
        let content = body.joinWithSeparator("\n")
        return self.requestWrite(url, method: Method.POST.rawValue, body: content, contentType: "application/newlines", ifUnmodifiedSince: ifUnmodifiedSince)
    }

    func requestPOST(url: NSURL, body: [JSON], ifUnmodifiedSince: Timestamp?) -> Request {
        return self.requestPOST(url, body: body.map { $0.toString(false) }, ifUnmodifiedSince: ifUnmodifiedSince)
    }

    /**
     * Returns true and fills the provided Deferred if our state shows that we're in backoff.
     * Returns false otherwise.
     */
    private func checkBackoff<T>(deferred: Deferred<Maybe<T>>) -> Bool {
        if let until = self.backoff.isInBackoff(NSDate.now()) {
            deferred.fill(Maybe<T>(failure: ServerInBackoffError(until: until)))
            return true
        }
        return false
    }

    private func doOp<T>(op: (NSURL) -> Request, path: String, f: (JSON) -> T?) -> Deferred<Maybe<StorageResponse<T>>> {

        let deferred = Deferred<Maybe<StorageResponse<T>>>(defaultQueue: self.resultQueue)

        if self.checkBackoff(deferred) {
            return deferred
        }

        // Special case "": we want /1.5/1234567 and not /1.5/1234567/.  See note about trailing slashes above.
        let url: NSURL
        if path == "" {
            url = self.serverURI // No trailing slash.
        } else {
            url = self.serverURI.URLByAppendingPathComponent(path)
        }

        let req = op(url)
        let handler = self.errorWrap(deferred) { (_, response, result) in
            if let json: JSON = result.value as? JSON {
                if let v = f(json) {
                    let storageResponse = StorageResponse<T>(value: v, response: response!)
                    deferred.fill(Maybe(success: storageResponse))
                } else {
                    deferred.fill(Maybe(failure: RecordParseError()))
                }
                return
            }

            deferred.fill(Maybe(failure: RecordParseError()))
        }

        req.responseParsedJSON(true, completionHandler: handler)
        return deferred
    }

    // Sync storage responds with a plain timestamp to a PUT, not with a JSON body.
    private func putResource<T>(path: String, body: JSON, ifUnmodifiedSince: Timestamp?, parser: (String) -> T?) -> Deferred<Maybe<StorageResponse<T>>> {
        let url = self.serverURI.URLByAppendingPathComponent(path)
        return self.putResource(url, body: body, ifUnmodifiedSince: ifUnmodifiedSince, parser: parser)
    }

    private func putResource<T>(URL: NSURL, body: JSON, ifUnmodifiedSince: Timestamp?, parser: (String) -> T?) -> Deferred<Maybe<StorageResponse<T>>> {

        let deferred = Deferred<Maybe<StorageResponse<T>>>(defaultQueue: self.resultQueue)

        if self.checkBackoff(deferred) {
            return deferred
        }

        let req = self.requestPUT(URL, body: body, ifUnmodifiedSince: ifUnmodifiedSince)
        let handler = self.errorWrap(deferred) { (_, response, result) in
            if let data = result.value as? String {
                if let v = parser(data) {
                    let storageResponse = StorageResponse<T>(value: v, response: response!)
                    deferred.fill(Maybe(success: storageResponse))
                } else {
                    deferred.fill(Maybe(failure: RecordParseError()))
                }
                return
            }

            deferred.fill(Maybe(failure: RecordParseError()))
        }

        let stringHandler = { (a: NSURLRequest?, b: NSHTTPURLResponse?, c: Result<String>) in
            return handler(a, b, c.isSuccess ? Result.Success(c.value!) : Result.Failure(c.data, c.error!))
        }

        req.responseString(encoding: nil, completionHandler: stringHandler)
        return deferred
    }

    private func getResource<T>(path: String, f: (JSON) -> T?) -> Deferred<Maybe<StorageResponse<T>>> {
        return doOp(self.requestGET, path: path, f: f)
    }

    private func deleteResource<T>(path: String, f: (JSON) -> T?) -> Deferred<Maybe<StorageResponse<T>>> {
        return doOp(self.requestDELETE, path: path, f: f)
    }

    func wipeStorage() -> Deferred<Maybe<StorageResponse<JSON>>> {
        // In Sync 1.5 it's preferred that we delete the root, not /storage.
        return deleteResource("", f: { $0 })
    }

    func getInfoCollections() -> Deferred<Maybe<StorageResponse<InfoCollections>>> {
        return getResource("info/collections", f: InfoCollections.fromJSON)
    }

    func getMetaGlobal() -> Deferred<Maybe<StorageResponse<MetaGlobal>>> {
        return getResource("storage/meta/global") { json in
            // We have an envelope.  Parse the meta/global record embedded in the 'payload' string.
            let envelope = EnvelopeJSON(json)
            if envelope.isValid() {
                return MetaGlobal.fromJSON(JSON.parse(envelope.payload))
            }
            return nil
        }
    }

    func getCryptoKeys(syncKeyBundle: KeyBundle, ifUnmodifiedSince: Timestamp?) -> Deferred<Maybe<StorageResponse<Record<KeysPayload>>>> {
        let syncKey = Keys(defaultBundle: syncKeyBundle)
        let encoder = RecordEncoder<KeysPayload>(decode: { KeysPayload($0) }, encode: { $0 })
        let encrypter = syncKey.encrypter("keys", encoder: encoder)
        let client = self.clientForCollection("crypto", encrypter: encrypter)
        return client.get("keys")
    }

    func uploadMetaGlobal(metaGlobal: MetaGlobal, ifUnmodifiedSince: Timestamp?) -> Deferred<Maybe<StorageResponse<Timestamp>>> {
        let payload = metaGlobal.asPayload()
        if payload.isError {
            return Deferred(value: Maybe(failure: MalformedMetaGlobalError()))
        }

        let record: JSON = JSON(["payload": payload.toString(), "id": "global"])
        return putResource("storage/meta/global", body: record, ifUnmodifiedSince: ifUnmodifiedSince, parser: decimalSecondsStringToTimestamp)
    }

    // The crypto/keys record is a special snowflake: it is encrypted with the Sync key bundle.  All other records are
    // encrypted with the bulk key bundle (including possibly a per-collection bulk key) stored in crypto/keys.
    func uploadCryptoKeys(keys: Keys, withSyncKeyBundle syncKeyBundle: KeyBundle, ifUnmodifiedSince: Timestamp?) -> Deferred<Maybe<StorageResponse<Timestamp>>> {
        let syncKey = Keys(defaultBundle: syncKeyBundle)
        let encoder = RecordEncoder<KeysPayload>(decode: { KeysPayload($0) }, encode: { $0 })
        let encrypter = syncKey.encrypter("keys", encoder: encoder)
        let client = self.clientForCollection("crypto", encrypter: encrypter)

        let record = Record(id: "keys", payload: keys.asPayload())
        return client.put(record, ifUnmodifiedSince: ifUnmodifiedSince)
    }

    // It would be convenient to have the storage client manage Keys, but of course we need to use a different set of
    // keys to fetch crypto/keys itself.  See uploadCryptoKeys.
    func clientForCollection<T: CleartextPayloadJSON>(collection: String, encrypter: RecordEncrypter<T>) -> Sync15CollectionClient<T> {
        let storage = self.serverURI.URLByAppendingPathComponent("storage", isDirectory: true)
        return Sync15CollectionClient(client: self, serverURI: storage, collection: collection, encrypter: encrypter)
    }
}

public class Sync15BatchClient<T: CleartextPayloadJSON> {
    private let config: InfoConfiguration

    private var records: [Record<T>] = []
    private let collectionClient: Sync15CollectionClient<T>
    private let collectionURI: NSURL

    init(config: InfoConfiguration, collectionURI: NSURL, collectionClient: Sync15CollectionClient<T>) {
        self.config = config
        self.collectionURI = collectionURI
        self.collectionClient = collectionClient
    }

    public func addRecords(records: [Record<T>]) {
        log.debug("Adding \(records.count) records into batch")
        self.records += records
    }

    // TODO: use I-U-S.
    // Each time we do the storage operation, we might receive a backoff notification.
    // For a success response, this will be on the subsequent request, which means we don't
    // have to worry about handling successes and failures mixed with backoffs here.

    public func commit(ifUnmodifiedSince: Timestamp? = nil, onCollectionUploaded: (POSTResult -> Void)) -> Success {

        // Need to deduce how big the data is we're sending across using this reducer
        let sizeReducer: (total: ByteCount, record: Record<T>) -> ByteCount = { total, record in
            return total + (self.collectionClient.serializeRecord(record) ?? "").utf8.count
        }

        let sizeOfRecords = records.reduce(0, combine: sizeReducer)

        if records.count > config.maxPostRecords || sizeOfRecords > config.maxPostBytes {

            // We have too many records for a single post so we'll either need to upload in a single batch or
            // multiple batches
            if records.count > config.maxBatchRecord || sizeOfRecords > config.maxBatchBytes {
                // TODO: Break into multiple batches
                return succeed()
            } else {
                return self.batchUpload(records, ifUnmodifiedSince: ifUnmodifiedSince, onCollectionUploaded: onCollectionUploaded)
            }
        } else {

            // We can just do a single post instead of batching
            log.debug("Batch fits within a single request. Submitting records in a single post.")
            return self.collectionClient.postToURI(self.collectionURI, records: records, ifUnmodifiedSince: ifUnmodifiedSince)
                >>== effect({ onCollectionUploaded($0.value) })
                >>> succeed
        }
    }

    public func batchUpload(records: [Record<T>], ifUnmodifiedSince: Timestamp?, onCollectionUploaded: (POSTResult -> Void)) -> Success {
        let batchingResult = batchesFromRecords(records, serializer: collectionClient.serializeRecord)
        guard var batches = batchingResult.successValue else {
            log.debug("Unable to generate batches from records submitted to batch client")
            return deferMaybe(batchingResult.failureValue!)
        }

        let firstBatch = batches.removeFirst()
        let lastBatch = batches.last ?? []

        return startBatch(firstBatch).bind { result in
            guard let token = result.successValue else {

                // Check if we didn't get a token back/batching isn't supported and push up records using regular single posts
                let error = result.failureValue!
                switch error {
                case is BatchingNotSupported:

                    // Walk through the batches, posting along the way and invoking onUpload
                    let perChunk: (lines: [String]) -> Success = { lines in
                        return self.collectionClient.postToURI(self.collectionURI, lines: lines, ifUnmodifiedSince: ifUnmodifiedSince)
                            >>== effect({ onCollectionUploaded($0.value) })
                            >>> succeed
                    }
                    return walk(batches, f: perChunk)
                default:
                    // Bubble up other errors
                    return deferMaybe(error)
                }
            }

            // Remove the last batch - we handle the last call in a special case.
            batches.removeLast()

            // When batching, each upload in the batch is uploaded to a temporary collection until we specif
            // commit=true. At this point, the temporary collection is pushed to the real collection on the server.
            // It is at this point we want to say the collection has been uploaded.
            return self.uploadBatches(token, batches: batches) >>> {
                return self.finishBatch(token, lines: lastBatch)
                    >>== effect({ onCollectionUploaded($0.value) })
                    >>> succeed
            }
        }
    }

    private func startBatch(lines: [String]) -> Deferred<Maybe<BatchToken>> {
        let batchStartParam = NSURLQueryItem(name: "batch", value: "true")
        let batchedURI = self.collectionURI.withQueryParams([batchStartParam])

        // Attempt to upload some records and see if we get back a token we can use for batches.
        return self.collectionClient.postToURI(batchedURI, lines: lines, ifUnmodifiedSince: nil) >>== { storageResponse in
            if let batchToken = storageResponse.value.batchToken {
                log.debug("Uploaded \(lines.count) records and received batch token \(batchToken)")
                return deferMaybe(batchToken)
            } else {
                log.debug("Uploaded \(lines.count) records but received no batch token")
                return deferMaybe(BatchingNotSupported())
            }
        }
    }

    private func uploadBatches(token: BatchToken, batches: [[String]]) -> Success {
        let batchQuery = NSURLQueryItem(name: "batch", value: token)
        let batchedURI = self.collectionURI.withQueryParams([batchQuery])

        let uploadBatch: (lines: [String]) -> Success = { lines in
            return self.collectionClient.postToURI(batchedURI, lines: lines, ifUnmodifiedSince: nil)
                >>> effect({ log.debug(("Uploaded \(lines.count) records for batch \(token)")) })
        }

        return walk(batches, f: uploadBatch)
    }

    private func finishBatch(token: BatchToken, lines: [String]) -> Deferred<Maybe<StorageResponse<POSTResult>>> {
        let batchQuery = NSURLQueryItem(name: "batch", value: token)
        let commitQuery = NSURLQueryItem(name: "commit", value: "true")
        let commitBatchURI = self.collectionURI.withQueryParams([batchQuery, commitQuery])
        return self.collectionClient.postToURI(commitBatchURI, lines: lines, ifUnmodifiedSince: nil)
    }

    public func batchesFromRecords<T>(records: [Record<T>], serializer: (Record<T>) -> String?) -> Maybe<[[String]]> {
        var failedGUID: GUID? = nil
        var largest: ByteCount = 0

        // Schwartzian transform -- decorate, sort, undecorate.
        func decorate(record: Record<T>) -> (String, ByteCount)? {
            guard failedGUID == nil else {
                // If we hit an over-sized record, or fail to serialize, we stop processing
                // everything: we don't want to upload only some of the user's bookmarks.
                return nil
            }

            guard let string = serializer(record) else {
                failedGUID = record.id
                return nil
            }

            let size = string.utf8.count
            if size > largest {
                largest = size
                if size > Sync15StorageClient.maxRecordSizeBytes {
                    // If we hit this case, we cannot ever successfully sync until the user
                    // takes action. Let's hope they do.
                    failedGUID = record.id
                    return nil
                }
            }

            return (string, size)
        }

        // Put small records first.
        let sorted = records.flatMap(decorate).sort { $0.1 < $1.1 }

        if let failed = failedGUID {
            return Maybe(failure: RecordTooLargeError(size: largest, guid: failed))
        }

        // Cut this up into chunks of a maximum size.
        var batches: [[String]] = []
        var batch: [String] = []
        var bytes = 0
        var count = 0
        sorted.forEach { (string, size) in
            let expectedBytes = bytes + size + 1   // Include newlines.
            if expectedBytes > Sync15StorageClient.maxPayloadSizeBytes ||
               count >= Sync15StorageClient.maxPayloadItemCount {
                batches.append(batch)
                batch = []
                bytes = 0
                count = 0
            }
            batch.append(string)
            bytes += size + 1
            count += 1
        }

        // Catch the last one.
        if !batch.isEmpty {
            batches.append(batch)
        }

        return Maybe(success: batches)
    }
}

private let DefaultInfoConfiguration = InfoConfiguration(maxRequestBytes: 1048576,
                                                         maxPostRecords: 100,
                                                         maxPostBytes: 1048576,
                                                         maxBatchRecord: 10000,
                                                         maxBatchBytes: 104857600)

/**
 * We'd love to nest this in the overall storage client, but Swift
 * forbids the nesting of a generic class inside another class.
 */
public class Sync15CollectionClient<T: CleartextPayloadJSON> {
    private let client: Sync15StorageClient
    private let encrypter: RecordEncrypter<T>
    private let collectionURI: NSURL
    private let collectionQueue = dispatch_queue_create("com.mozilla.sync.collectionclient", DISPATCH_QUEUE_SERIAL)
    private let infoConfig = DefaultInfoConfiguration

    init(client: Sync15StorageClient, serverURI: NSURL, collection: String, encrypter: RecordEncrypter<T>) {
        self.client = client
        self.encrypter = encrypter
        self.collectionURI = serverURI.URLByAppendingPathComponent(collection, isDirectory: false)
    }

    private func uriForRecord(guid: String) -> NSURL {
        return self.collectionURI.URLByAppendingPathComponent(guid)
    }

    private func postToURI(uri: NSURL, lines: [String], ifUnmodifiedSince: Timestamp?) -> Deferred<Maybe<StorageResponse<POSTResult>>> {
        let deferred = Deferred<Maybe<StorageResponse<POSTResult>>>(defaultQueue: client.resultQueue)

        if self.client.checkBackoff(deferred) {
            return deferred
        }

        let req = client.requestPOST(uri, body: lines, ifUnmodifiedSince: nil)
        req.responsePartialParsedJSON(queue: collectionQueue, completionHandler: self.client.errorWrap(deferred) { (_, response, result) in
            if let json: JSON = result.value as? JSON,
               let result = POSTResult.fromJSON(json) {
                let storageResponse = StorageResponse(value: result, response: response!)
                deferred.fill(Maybe(success: storageResponse))
                return
            } else {
                log.warning("Couldn't parse JSON response.")
            }
            deferred.fill(Maybe(failure: RecordParseError()))
        })

        return deferred
    }

    private func postToURI(uri: NSURL, records: [Record<T>], ifUnmodifiedSince: Timestamp?) -> Deferred<Maybe<StorageResponse<POSTResult>>> {
        let lines = optFilter(records.map(serializeRecord))
        return postToURI(self.collectionURI, lines: lines, ifUnmodifiedSince: ifUnmodifiedSince)
    }

    public func newBatchOperation() -> Sync15BatchClient<T> {
        return Sync15BatchClient(config: infoConfig, collectionURI: self.collectionURI, collectionClient: self)
    }

    // Exposed so we can batch by size.
    public func serializeRecord(record: Record<T>) -> String? {
        return self.encrypter.serializer(record)?.toString(false)
    }

    public func post(lines: [String], ifUnmodifiedSince: Timestamp?) -> Deferred<Maybe<StorageResponse<POSTResult>>> {
        return self.postToURI(self.collectionURI, lines: lines, ifUnmodifiedSince: ifUnmodifiedSince)
    }

    public func post(records: [Record<T>], ifUnmodifiedSince: Timestamp?) -> Deferred<Maybe<StorageResponse<POSTResult>>> {
        return self.postToURI(self.collectionURI, records: records, ifUnmodifiedSince: ifUnmodifiedSince)
    }

    public func put(record: Record<T>, ifUnmodifiedSince: Timestamp?) -> Deferred<Maybe<StorageResponse<Timestamp>>> {
        if let body = self.encrypter.serializer(record) {
            return self.client.putResource(uriForRecord(record.id), body: body, ifUnmodifiedSince: ifUnmodifiedSince, parser: decimalSecondsStringToTimestamp)
        }
        return deferMaybe(RecordParseError())
    }

    public func get(guid: String) -> Deferred<Maybe<StorageResponse<Record<T>>>> {
        let deferred = Deferred<Maybe<StorageResponse<Record<T>>>>(defaultQueue: client.resultQueue)

        if self.client.checkBackoff(deferred) {
            return deferred
        }

        let req = client.requestGET(uriForRecord(guid))
        req.responsePartialParsedJSON(queue:collectionQueue, completionHandler: self.client.errorWrap(deferred) { (_, response, result) in

            if let json: JSON = result.value as? JSON {
                let envelope = EnvelopeJSON(json)
                let record = Record<T>.fromEnvelope(envelope, payloadFactory: self.encrypter.factory)
                if let record = record {
                    let storageResponse = StorageResponse(value: record, response: response!)
                    deferred.fill(Maybe(success: storageResponse))
                    return
                }
            } else {
                log.warning("Couldn't parse JSON response.")
            }

            deferred.fill(Maybe(failure: RecordParseError()))
        })

        return deferred
    }

    /**
     * Unlike every other Sync client, we use the application/json format for fetching
     * multiple requests. The others use application/newlines. We don't want to write
     * another Serializer, and we're loading everything into memory anyway.
     *
     * It is the caller's responsibility to check whether the returned payloads are invalid.
     *
     * Only non-JSON and malformed envelopes will be dropped.
     */
    public func getSince(since: Timestamp, sort: SortOption?=nil, limit: Int?=nil, offset: String?=nil) -> Deferred<Maybe<StorageResponse<[Record<T>]>>> {
        let deferred = Deferred<Maybe<StorageResponse<[Record<T>]>>>(defaultQueue: client.resultQueue)

        // Fills the Deferred for us.
        if self.client.checkBackoff(deferred) {
            return deferred
        }

        var params: [NSURLQueryItem] = [
            NSURLQueryItem(name: "full", value: "1"),
            NSURLQueryItem(name: "newer", value: millisecondsToDecimalSeconds(since)),
        ]

        if let offset = offset {
            params.append(NSURLQueryItem(name: "offset", value: offset))
        }

        if let limit = limit {
            params.append(NSURLQueryItem(name: "limit", value: "\(limit)"))
        }

        if let sort = sort {
            params.append(NSURLQueryItem(name: "sort", value: sort.rawValue))
        }

        log.debug("Issuing GET with newer = \(since).")
        let req = client.requestGET(self.collectionURI.withQueryParams(params))

        req.responsePartialParsedJSON(queue: collectionQueue, completionHandler: self.client.errorWrap(deferred) { (_, response, result) in

            log.verbose("Response is \(response).")
            guard let json: JSON = result.value as? JSON else {
                log.warning("Non-JSON response.")
                deferred.fill(Maybe(failure: RecordParseError()))
                return
            }

            guard let arr = json.asArray else {
                log.warning("Non-array response.")
                deferred.fill(Maybe(failure: RecordParseError()))
                return
            }

            func recordify(json: JSON) -> Record<T>? {
                let envelope = EnvelopeJSON(json)
                return Record<T>.fromEnvelope(envelope, payloadFactory: self.encrypter.factory)
            }

            let records = arr.flatMap(recordify)
            let response = StorageResponse(value: records, response: response!)
            deferred.fill(Maybe(success: response))
        })

        return deferred
    }
}
