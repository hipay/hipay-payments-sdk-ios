import Foundation
import HiPayCore
import HiPayFullservice
import XCTest
@testable import HiPayCard

/// PI-6048 — field-validation Gherkin scenarios, verbatim in French above each test.
/// Controller-level over the shared commonMain contract — NETWORK-FREE (partial,
/// non-Luhn prefixes only, so the backend resolver never fires). Message assertions
/// go through `HiPayCardStrings.localized` so they hold on any device locale.
/// Mirrors `CmpCardValidationGherkinTest` / `CardEntryValidationGherkinTest` (Android).
final class HiPayCardValidationGherkinTests: XCTestCase {

    private let configuration = HiPayConfiguration(
        username: "validation-swift-test-user", password: "pw", environment: .stage
    )

    @MainActor
    private func makeController(allowed: [HiPayCardNetwork] = []) -> HiPayCardEntryController {
        HiPayCardEntryController(configuration: configuration, allowedNetworks: allowed).withOfflineCeiling()
    }

    @MainActor
    private func type(number: String, on controller: HiPayCardEntryController) {
        controller.cardNumber = number
        controller.numberEdited()
    }

    private func message(_ key: CardEntryStringKey) -> String {
        HiPayCardStrings.localized(key)
    }

    // Scénario : Numéro de carte invalide
    //   Étant donné que le champ numéro de carte contient une valeur invalide ou incomplète
    //   Quand l'utilisateur quitte le champ
    //   Alors le champ passe en état erreur
    //   Et le message "Numéro de carte invalide" est affiché
    @MainActor
    func test_invalidNumber_errorsOnBlur() {
        let controller = makeController()
        type(number: "4111111111111112", on: controller) // 16 digits, Luhn fails
        XCTAssertNil(controller.numberSlotError) // nothing while the field still has focus
        controller.markBlurred(.number)
        XCTAssertEqual(message(.errorInvalidNumber), controller.numberSlotError?.message)
    }

    // Scénario : Vérification des patterns à la saisie du premier numéro de carte
    //   Si le numéro ne respecte pas les patterns des réseaux supportés, l'erreur
    //   "Numéro de carte invalide" est affichée directement à la saisie — sans blur.
    @MainActor
    func test_impossiblePrefix_errorsImmediatelyWhileTyping() {
        let controller = makeController()
        type(number: "1", on: controller) // no supported network starts with 1
        XCTAssertEqual(message(.errorInvalidNumber), controller.numberSlotError?.message) // no blur
        type(number: "", on: controller) // clearing the digit clears the error
        XCTAssertNil(controller.numberSlotError)
        type(number: "3", on: controller) // could still become 34/37 (Amex)
        XCTAssertNil(controller.numberSlotError)
        type(number: "30", on: controller) // neither 34 nor 37 — unrepairable
        XCTAssertEqual(message(.errorInvalidNumber), controller.numberSlotError?.message)
    }

    // Scénario : Type de carte non autorisé — détection locale NON AMBIGUË (refinement 2026-07-20)
    //   Seul "cb" autorisé ; un préfixe Amex ne peut jamais être une co-marque CB
    //   → "Type de carte non autorisé" s'affiche immédiatement pendant la saisie (sans blur).
    @MainActor
    func test_unambiguousDisallowedNetwork_errorsImmediatelyWhileTyping() {
        let controller = makeController(allowed: [.cb])
        type(number: "3714", on: controller) // Amex prefix
        XCTAssertEqual(message(.errorNetworkNotAuthorized), controller.numberSlotError?.message) // no blur
    }

    // Scénario : Cas AMBIGU — Visa détecté avec seul "cb" autorisé (contrat 2026-07-17 préservé)
    //   Une cobrandée CB+Visa est localement "visa" → aucune erreur réseau pendant la saisie ;
    //   seul "Numéro de carte incomplet" au blur.
    @MainActor
    func test_ambiguousCoBrand_staysQuietUntilBlurThenIncomplete() {
        let controller = makeController(allowed: [.cb])
        type(number: "4111", on: controller) // locally Visa — could be a CB+Visa co-brand
        XCTAssertNil(controller.numberSlotError)
        controller.markBlurred(.number)
        XCTAssertEqual(message(.errorIncompleteNumber), controller.numberSlotError?.message)
    }

    // Scénario : Date d'expiration dans le passé
    //   Quand l'utilisateur quitte le champ, le champ passe en état erreur
    //   et le message "Date expirée" est affiché.
    @MainActor
    func test_pastExpiry_errorsOnBlur() {
        let controller = makeController()
        controller.expiry = "1220" // 12/2020 — past
        controller.expiryEdited()
        XCTAssertEqual("12/20", controller.expiry) // MM/YY auto-format on the way
        XCTAssertNil(controller.expiryError)
        controller.markBlurred(.expiry)
        XCTAssertEqual(message(.errorExpired), controller.expiryError)
    }

    // Scénario : Année de la date d'expiration max 15 ans dans le futur
    @MainActor
    func test_expiryBeyondFifteenYears_errorsOnBlur() {
        let controller = makeController()
        let year = Calendar.current.component(.year, from: Date())
        controller.expiry = "12" + String(format: "%02d", (year + 16) % 100)
        controller.expiryEdited()
        controller.markBlurred(.expiry)
        XCTAssertEqual(message(.errorInvalidExpiry), controller.expiryError)
        // ...while +15 is still accepted.
        controller.expiry = "12" + String(format: "%02d", (year + 15) % 100)
        controller.expiryEdited()
        XCTAssertNil(controller.expiryError)
    }

    // Plan du scénario : CVV invalide selon le réseau — | visa | "12" | amex | "123" |
    @MainActor
    func test_tooShortCvc_errorsOnBlurPerNetwork() {
        let visa = makeController()
        type(number: "4111", on: visa) // visa prefix → CVC = 3
        visa.cvc = "12"
        visa.cvcEdited()
        XCTAssertNil(visa.cvcError)
        visa.markBlurred(.cvc)
        XCTAssertEqual(message(.errorIncompleteCvv), visa.cvcError)

        let amex = makeController()
        type(number: "3714", on: amex) // amex prefix → CVC = 4
        amex.cvc = "123"
        amex.cvcEdited()
        amex.markBlurred(.cvc)
        XCTAssertEqual(message(.errorIncompleteCvv), amex.cvcError)
        amex.cvc = "1234"
        amex.cvcEdited()
        XCTAssertNil(amex.cvcError)
    }

    // Scénario : CVV désactivé pour Bancontact
    //   Le champ CVV est désactivé et non saisissable (la vue lie `.disabled` sur
    //   `isCvcRequired`), aucun message d'erreur CVV.
    @MainActor
    func test_bancontact_disablesCvcWithoutError() {
        let controller = makeController()
        type(number: "6703", on: controller) // local BCMC prefix (partial — no backend)
        XCTAssertFalse(controller.isCvcRequired)
        controller.markBlurred(.cvc)
        XCTAssertNil(controller.cvcError)
    }

    // Scénario : Nom du porteur trop court
    //   Moins de 3 caractères → au blur, "Minimum 3 caractères".
    @MainActor
    func test_holderUnderThreeChars_errorsOnBlur() {
        let controller = makeController()
        controller.holder = "ab"
        controller.holderEdited()
        XCTAssertNil(controller.holderError)
        controller.markBlurred(.holder)
        XCTAssertEqual(message(.errorHolderTooShort), controller.holderError)
        controller.holder = "ABC"
        controller.holderEdited()
        XCTAssertNil(controller.holderError)
    }

    // Scénario : Nom du porteur bloqué à 60 caractères
    //   Quand l'utilisateur saisit un 61ème caractère, il n'est pas accepté.
    @MainActor
    func test_holderBlocksTheSixtyFirstCharacter() {
        let controller = makeController()
        controller.holder = String(repeating: "a", count: 61)
        controller.holderEdited()
        XCTAssertEqual(String(repeating: "A", count: 60), controller.holder)
    }

    // Scénario : Pas plus de 8 digits dans le champs card holder
    @MainActor
    func test_holderKeepsAtMostEightDigits() {
        let controller = makeController()
        controller.holder = "jean 123456789" // 9 digits typed
        controller.holderEdited()
        XCTAssertEqual("JEAN 12345678", controller.holder) // 9th digit dropped
    }

    // Scénario : Pas de lettres dans le champs numéro de carte
    // Scénario : Pas de lettres dans le champs date d'expiration
    // Scénario : Pas de lettres dans le champs CVV
    @MainActor
    func test_lettersAreRejectedInNumberExpiryAndCvc() {
        let controller = makeController()
        type(number: "4a1b1c1", on: controller)
        XCTAssertEqual("4111", controller.cardNumber)
        controller.expiry = "1a2b3c0"
        controller.expiryEdited()
        XCTAssertEqual("12/30", controller.expiry)
        controller.cvc = "1x2y3"
        controller.cvcEdited()
        XCTAssertEqual("123", controller.cvc)
    }

    // Scénario : Formattage des numéros de cartes en fonction du réseau
    //   Groupes de 4 chiffres, sauf Amex : 4-6-5 — et la saisie est plafonnée à la
    //   longueur du réseau détecté (Amex 15, Visa 16…).
    @MainActor
    func test_numberFormatsAndCapsPerNetwork() {
        let controller = makeController()
        type(number: "4111111111111111", on: controller)
        XCTAssertEqual("4111 1111 1111 1111", controller.cardNumber)
        type(number: "37144963539843112345", on: controller) // 20 digits typed on an Amex (15)
        XCTAssertEqual("3714 496353 98431", controller.cardNumber)
    }
}
