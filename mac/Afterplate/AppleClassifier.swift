import CoreML
import Vision
import CoreGraphics

/// "애플사진": a photo that belongs to a restaurant visit worth reviewing —
/// not the same as "food is visible". Vision's 1,303 labels answer the
/// second question, and a dumpling-mix box, a menu board or a kiosk screen
/// all pass it. SigLIP (google/siglip-base-patch16-224, Apache 2.0, image
/// tower converted to Core ML by mac/model/get-model.sh; not in the source,
/// only in the notarized app) compares the photo with sentences that
/// describe the situation instead, and the sentences were fixed before any
/// result was looked at; they live in apple-prompts.json as text embeddings,
/// so no text model ships. The Vision rules alone missed a laid outdoor
/// table (food 0.02) and a bowl of 빙수 (0.13) outright.
///
/// SigLIP replaced MobileCLIP-S2, whose weights are licensed for research
/// only. Same sentences, same 0.5 bar, nothing tuned; on 134 posted visits
/// and 132 marked not-a-meal, with the Vision rules alongside: SigLIP caught
/// 132 posted and 106 not-a-meal, MobileCLIP 129 and 122, Vision alone 107
/// and 70. (The not-a-meal visits were all ones MobileCLIP had surfaced.)
enum AppleClassifier {
    struct Prompts: Decodable {
        var apple: [String]
        var not: [String]
        var coffee_index: Int
        var embeddings: [[Float]]
        /// "mainly of food / a person / a place / an object": a person at a
        /// cafe table with a coffee in front of them is not an 애플사진
        /// but is worth remembering as a restaurant they
        /// went to. Food must come first in the frame for the review flow.
        var subject: [String]
        var subject_embeddings: [[Float]]
        /// The model's logit scale: how sharply similarities become
        /// probabilities.
        var scale: Float
    }

    struct Verdict: Sendable {
        /// Share of probability on the 애플 sentences.
        var apple: Float
        /// Probability that the photo is mainly of food (vs a person, a
        /// place, an object).
        var mainlyFood: Float
    }

    /// The photo is 애플 when the apple sentences hold this much of the
    /// probability. Chosen for MobileCLIP on the judged visits, half for
    /// picking, half for checking, and kept unchanged for SigLIP.
    static let threshold: Float = 0.5

    nonisolated private static let model: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "SigLIPImage", withExtension: "mlmodelc") else {
            print("[AppleClassifier] model missing from bundle")
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do { return try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config)) }
        catch { print("[AppleClassifier] model failed to load: \(error)"); return nil }
    }()

    nonisolated private static let prompts: Prompts? = {
        guard let url = Bundle.main.url(forResource: "apple-prompts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Prompts.self, from: data) else {
            print("[AppleClassifier] prompts missing from bundle")
            return nil
        }
        return p
    }()

    nonisolated static var available: Bool { model != nil && prompts != nil }

    /// Probability that the photo is 애플, or nil when the model is absent.
    /// `people` is Vision's people score: when the best sentence is "a person
    /// holding a takeout coffee cup" but nobody is in the frame, that
    /// sentence is dropped and the photo is judged again — a latte on a cafe
    /// table is 애플, a coffee in someone's hand is not.
    nonisolated static func score(_ image: CGImage, people: Float) -> Verdict? {
        guard let model, let prompts else { return nil }
        let request = VNCoreMLRequest(model: model)
        // Same as the model's own preprocessing: the whole photo squeezed to
        // 224×224, no crop.
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let feature = request.results?.first as? VNCoreMLFeatureValueObservation,
              let array = feature.featureValue.multiArrayValue else { return nil }
        var embedding = (0..<array.count).map { Float(truncating: array[$0]) }
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        embedding = embedding.map { $0 / norm }

        var sims = prompts.embeddings.map { row -> Float in
            zip(row, embedding).reduce(0) { $0 + $1.0 * $1.1 }
        }
        func appleShare(_ sims: [Float]) -> (share: Float, top: Int) {
            let top = sims.indices.max { sims[$0] < sims[$1] } ?? 0
            let peak = sims[top]
            let weights = sims.map { exp(prompts.scale * ($0 - peak)) }
            let total = weights.reduce(0, +)
            let apple = weights.prefix(prompts.apple.count).reduce(0, +)
            return (apple / total, top)
        }
        var result = appleShare(sims)
        if result.top == prompts.coffee_index, people < 0.5 {
            sims[prompts.coffee_index] = -.infinity
            result = appleShare(sims)
        }
        let subject = prompts.subject_embeddings.map { row -> Float in
            zip(row, embedding).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let peak = subject.max() ?? 0
        let weights = subject.map { exp(prompts.scale * ($0 - peak)) }
        let mainlyFood = weights[0] / weights.reduce(0, +)
        return Verdict(apple: result.share, mainlyFood: mainlyFood)
    }
}
