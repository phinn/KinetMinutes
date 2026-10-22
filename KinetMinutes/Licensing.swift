// Licensing.swift — 1.1 Pro licensing: StoreKit 2 lifetime unlock (MAS build)
// with a Developer ID direct-install override (defaults key proOverride),
// mirroring AiosPulse's SubscriptionGate.localOverride pattern.
//
// MAS app review requires the purchase flow itself to use Apple's IAP, so the
// in-app Upgrade sheet always opens the StoreKit sheet in sandbox/TestFlight.
// The defaults override exists for the non-sandboxed website build (Paddle
// license is verified at install time) and for internal QA builds.
//
// StoreKit 2: Transaction.currentEntitlements lists active non-consumables.
// A transaction is accepted as "Pro" when:
//   - productID matches our non-consumable id, AND
//   - verification result is .verified, AND
//   - revocationDate == nil (not refunded/revoked by CS).
// Listener keeps entitlement fresh across the app's lifetime (family sharing
// or refunds while running update currentEntitlements on next foreground).

import Foundation
import StoreKit

// Note: NOT @MainActor — the class is touched from AVAudioEngine taps and
// pipeline Tasks; minimal-concurrency Swift treats the Bool as plain state.
final class Licensing: ObservableObject {
    static let shared = Licensing()

    /// MAS non-consumable product id. Bumped in App Store Connect IAP config.
    static let proProductID = "com.kinet.minutes.pro"

    @Published private(set) var isPro: Bool = false
    @Published private(set) var priceString: String? = nil   // localized, from Product
    @Published private(set) var purchaseState: PurchaseState = .idle

    enum PurchaseState { case idle, purchasing, succeeded, failed(String) }

    private var updatesTask: Task<Void, Never>? = nil

    private init() {
        isPro = Self.manualOverride || Self.cachedEntitlement
        // StoreKit 2 listener; initial refresh is kicked from AppDelegate after
        // launch (Task { await Licensing.shared.refresh() }) — init stays sync.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await self.refresh() }
    }

    deinit { updatesTask?.cancel() }

    // MARK: - entitlement sources

    /// Developer ID direct build: `defaults write com.kinet.minutes.app proOverride -bool YES`
    private static var manualOverride: Bool {
        UserDefaults.standard.bool(forKey: "proOverride")
    }

    /// Last positively-verified entitlement, persisted so Pro status shows
    /// instantly on next launch even before StoreKit finishes currentEntitlements.
    private static var cachedEntitlement: Bool {
        UserDefaults.standard.bool(forKey: "proUnlocked")
    }

    // MARK: - refresh / purchase / restore

    func refresh() async {
        #if APPSTORE
        await refreshFromStoreKit()
        #else
        // Website/direct build: StoreKit may have no receipt; override decides.
        await refreshFromStoreKit()   // still try, costs nothing
        isPro = isPro || Self.manualOverride
        #endif
    }

    private func refreshFromStoreKit() async {
        var found = false
        for await ent in Transaction.currentEntitlements {
            if case .verified(let t) = ent, t.productID == Self.proProductID,
               t.revocationDate == nil {
                found = true
                break
            }
        }
        isPro = found || Self.manualOverride
        Licensing.cachedEntitlementFlag = found
        if found { await loadPrice() }
    }

    /// Load localized price for the Upgrade menu item ("Upgrade — ¥198").
    func loadPrice() async {
        guard priceString == nil else { return }
        do {
            let products = try await Product.products(for: [Self.proProductID])
            priceString = products.first?.displayPrice
        } catch {
            priceString = nil   // offline / not configured yet — menu shows plain "Upgrade"
        }
    }

    func purchase() async {
        do {
            guard let product = try await Product.products(for: [Self.proProductID]).first else {
                purchaseState = .failed(L10n.string("Purchase unavailable"))
                return
            }
            purchaseState = .purchasing
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let t) = verification {
                    await t.finish()
                    isPro = true
                    Licensing.cachedEntitlementFlag = true
                    purchaseState = .succeeded
                } else {
                    purchaseState = .failed(L10n.string("Purchase could not be verified"))
                }
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                // Ask-to-buy / SCA — entitlement arrives via Transaction.updates listener.
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshFromStoreKit()
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Transaction.updates handling

    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let t):
            await t.finish()
            if t.productID == Self.proProductID, t.revocationDate == nil {
                isPro = true
                Licensing.cachedEntitlementFlag = true
            }
        case .unverified:
            break
        @unknown default:
            break
        }
    }
}

// Tiny nonisolated sugar so sync call sites (pipeline free wall) stay simple.
extension Licensing {
    static var cachedEntitlementFlag: Bool {
        get { UserDefaults.standard.bool(forKey: "proUnlocked") }
        set { UserDefaults.standard.set(newValue, forKey: "proUnlocked") }
    }
}
