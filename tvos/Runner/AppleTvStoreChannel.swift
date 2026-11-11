import Flutter
import StoreKit

/// Lambent Enhance on the Apple TV's App Store (lib/data/services/enhance_store_tvos.dart). The in_app_purchase plugin has no
/// tvOS side, so this is StoreKit 2 directly: the products, a purchase, restoring, and every transaction handed to Dart as its
/// signed form (JWS), which Lambent Server passes to the licence service to check with Apple. A transaction stays open until Dart
/// says the server confirmed it, so an unconfirmed purchase comes back on the next launch.
@MainActor
final class AppleTvStoreChannel {
    private let channel: FlutterMethodChannel
    private var products: [String: Product] = [:]
    /// Delivered to Dart and not yet finished, by transaction id.
    private var open: [String: Transaction] = [:]
    private var updates: Task<Void, Never>?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "lambent/store", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]
        switch call.method {
        case "isAvailable":
            result(AppStore.canMakePayments)
        case "listen":
            listen()
            result(nil)
        case "products":
            let ids = arguments?["ids"] as? [String] ?? []
            Task { @MainActor in
                do {
                    let found = try await Product.products(for: ids)
                    for product in found { self.products[product.id] = product }
                    result(found.map { ["id": $0.id, "title": $0.displayName, "price": $0.displayPrice] })
                } catch {
                    result(FlutterError(code: "store", message: error.localizedDescription, details: nil))
                }
            }
        case "buy":
            guard let id = arguments?["id"] as? String, let product = products[id] else {
                result(FlutterError(code: "unknown_product", message: "No such product was loaded", details: nil))
                return
            }
            Task { @MainActor in
                do {
                    switch try await product.purchase() {
                    case .success(let verification):
                        self.deliver(verification, status: "purchased")
                    case .pending:
                        // Ask to Buy, or a payment that needs approving: the result arrives as a transaction update.
                        self.send(["productId": id, "status": "pending"])
                    case .userCancelled:
                        self.send(["productId": id, "status": "canceled"])
                    @unknown default:
                        self.send(["productId": id, "status": "error"])
                    }
                } catch StoreKitError.userCancelled {
                    // Backing out of the sheet can also arrive as a thrown error.
                    self.send(["productId": id, "status": "canceled"])
                } catch {
                    NSLog("Lambent store: purchase of %@ failed: %@", id, String(describing: error))
                    self.send(["productId": id, "status": "error"])
                }
                result(nil)
            }
        case "restore":
            Task { @MainActor in
                // Asks for the Apple account's password; a cancel leaves what the device already knows.
                try? await AppStore.sync()
                for await verification in Transaction.currentEntitlements {
                    self.deliver(verification, status: "restored")
                }
                result(nil)
            }
        case "finish":
            guard let id = arguments?["id"] as? String, let transaction = open.removeValue(forKey: id) else {
                result(nil)
                return
            }
            Task { @MainActor in
                await transaction.finish()
                result(nil)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Purchases made elsewhere, renewals, approved Ask to Buy requests, and whatever an earlier launch left unfinished.
    private func listen() {
        guard updates == nil else { return }
        updates = Task { @MainActor [weak self] in
            for await verification in Transaction.unfinished {
                self?.deliver(verification, status: "purchased")
            }
            for await verification in Transaction.updates {
                self?.deliver(verification, status: "purchased")
            }
        }
    }

    /// The JWS goes to Dart whether or not this device could verify it: the licence service checks it with Apple either way.
    private func deliver(_ verification: VerificationResult<Transaction>, status: String) {
        let transaction = verification.unsafePayloadValue
        // A refunded or family-revoked purchase grants nothing; finish it so it stops coming back.
        if transaction.revocationDate != nil {
            Task { await transaction.finish() }
            return
        }
        let id = String(transaction.id)
        open[id] = transaction
        send([
            "productId": transaction.productID,
            "status": status,
            "jws": verification.jwsRepresentation,
            "id": id,
        ])
    }

    private func send(_ update: [String: Any]) {
        channel.invokeMethod("update", arguments: update)
    }
}
