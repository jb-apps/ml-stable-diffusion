// For licensing see accompanying LICENSE.md file.
// Copyright (C) 2022 Apple Inc. All Rights Reserved.

import Accelerate
import CoreML

@available(iOS 16.2, macOS 13.1, *)
public protocol Scheduler {
    /// Number of diffusion steps performed during training
    var trainStepCount: Int { get }

    /// Number of inference steps to be performed
    var inferenceStepCount: Int { get }

    /// Training diffusion time steps index by inference time step
    var timeSteps: [Int] { get }

    /// Training diffusion time steps index by inference time step
    func calculateTimesteps(strength: Float?) -> [Int]

    /// Schedule of betas which controls the amount of noise added at each timestep
    var betas: [Float] { get }

    /// 1 - betas
    var alphas: [Float] { get }

    /// Cached cumulative product of alphas
    var alphasCumProd: [Float] { get }

    /// Standard deviation of the initial noise distribution
    var initNoiseSigma: Float { get }

    /// Denoised latents
    var modelOutputs: [MLShapedArray<Float32>] { get }

    /// Compute a de-noised image sample and step scheduler state
    ///
    /// - Parameters:
    ///   - output: The predicted residual noise output of learned diffusion model
    ///   - timeStep: The current time step in the diffusion chain
    ///   - sample: The current input sample to the diffusion model
    /// - Returns: Predicted de-noised sample at the previous time step
    /// - Postcondition: The scheduler state is updated.
    ///   The state holds the current sample and history of model output noise residuals
    func step(
        output: MLShapedArray<Float32>,
        timeStep t: Int,
        sample s: MLShapedArray<Float32>
    ) -> MLShapedArray<Float32>
}

@available(iOS 16.2, macOS 13.1, *)
public extension Scheduler {
    var initNoiseSigma: Float { 1 }
}

@available(iOS 16.2, macOS 13.1, *)
public extension Scheduler {
    /// Compute weighted sum of shaped arrays of equal shapes
    ///
    /// - Parameters:
    ///   - weights: The weights each array is multiplied by
    ///   - values: The arrays to be weighted and summed
    /// - Returns: sum_i weights[i]*values[i]
    func weightedSum(_ weights: [Double], _ values: [MLShapedArray<Float32>]) -> MLShapedArray<Float32> {
        let scalarCount = values.first!.scalarCount
        assert(weights.count > 1 && values.count == weights.count)
        assert(values.allSatisfy({ $0.scalarCount == scalarCount }))

        return MLShapedArray(unsafeUninitializedShape: values.first!.shape) { scalars, _ in
            scalars.initialize(repeating: 0.0)
            for i in 0 ..< values.count {
                let w = Float(weights[i])
                values[i].withUnsafeShapedBufferPointer { buffer, _, _ in
                    assert(buffer.count == scalarCount)
                    // scalars[j] = w * values[i].scalars[j]
                    cblas_saxpy(Int32(scalarCount), w, buffer.baseAddress, 1, scalars.baseAddress, 1)
                }
            }
        }
    }
    
    func addNoise(
        originalSample: MLShapedArray<Float32>,
        noise: [MLShapedArray<Float32>],
        strength: Float
    ) -> [MLShapedArray<Float32>] {
        let startStep = max(inferenceStepCount - Int(Float(inferenceStepCount) * strength), 0)
        let alphaProdt = alphasCumProd[timeSteps[startStep]]
        let betaProdt = 1 - alphaProdt
        let sqrtAlphaProdt = sqrt(alphaProdt)
        let sqrtBetaProdt = sqrt(betaProdt)
        
        let noisySamples = noise.map {
            weightedSum(
                [Double(sqrtAlphaProdt), Double(sqrtBetaProdt)],
                [originalSample, $0]
            )
        }

        return noisySamples
    }
}

// MARK: - Timesteps

@available(iOS 16.2, macOS 13.1, *)
public extension Scheduler {
    func calculateTimesteps(strength: Float?) -> [Int] {
        guard let strength else { return timeSteps }
        let startStep = max(inferenceStepCount - Int(Float(inferenceStepCount) * strength), 0)
        let actualTimesteps = Array(timeSteps[startStep...])
        return actualTimesteps
    }
}

// MARK: - BetaSchedule

/// How to map a beta range to a sequence of betas to step over
@available(iOS 16.2, macOS 13.1, *)
public enum BetaSchedule {
    /// Linear stepping between start and end
    case linear
    /// Steps using linspace(sqrt(start),sqrt(end))^2
    case scaledLinear
}

// MARK: - PNDMScheduler

/// A scheduler used to compute a de-noised image
///
///  This implementation matches:
///  [Hugging Face Diffusers PNDMScheduler](https://github.com/huggingface/diffusers/blob/main/src/diffusers/schedulers/scheduling_pndm.py)
///
/// This scheduler uses the pseudo linear multi-step (PLMS) method only, skipping pseudo Runge-Kutta (PRK) steps
@available(iOS 16.2, macOS 13.1, *)
public final class PNDMScheduler: Scheduler {
    public let trainStepCount: Int
    public let inferenceStepCount: Int
    public let betas: [Float]
    public let alphas: [Float]
    public let alphasCumProd: [Float]
    public let timeSteps: [Int]

    public let alpha_t: [Float]
    public let sigma_t: [Float]
    public let lambda_t: [Float]

    public private(set) var modelOutputs: [MLShapedArray<Float32>] = []

    // Internal state
    var counter: Int
    var ets: [MLShapedArray<Float32>]
    var currentSample: MLShapedArray<Float32>?

    /// Create a scheduler that uses a pseudo linear multi-step (PLMS)  method
    ///
    /// - Parameters:
    ///   - stepCount: Number of inference steps to schedule
    ///   - trainStepCount: Number of training diffusion steps
    ///   - betaSchedule: Method to schedule betas from betaStart to betaEnd
    ///   - betaStart: The starting value of beta for inference
    ///   - betaEnd: The end value for beta for inference
    /// - Returns: A scheduler ready for its first step
    public init(
        stepCount: Int = 50,
        trainStepCount: Int = 1000,
        betaSchedule: BetaSchedule = .scaledLinear,
        betaStart: Float = 0.00085,
        betaEnd: Float = 0.012
    ) {
        self.trainStepCount = trainStepCount
        self.inferenceStepCount = stepCount

        switch betaSchedule {
        case .linear:
            self.betas = linspace(betaStart, betaEnd, trainStepCount)
        case .scaledLinear:
            self.betas = linspace(pow(betaStart, 0.5), pow(betaEnd, 0.5), trainStepCount).map({ $0 * $0 })
        }
        self.alphas = betas.map({ 1.0 - $0 })
        var alphasCumProd = self.alphas
        for i in 1..<alphasCumProd.count {
            alphasCumProd[i] *= alphasCumProd[i -  1]
        }
        self.alphasCumProd = alphasCumProd
        let stepsOffset = 1 // For stable diffusion
        let stepRatio = Float(trainStepCount / stepCount )
        let forwardSteps = (0..<stepCount).map {
            Int((Float($0) * stepRatio).rounded()) + stepsOffset
        }

        self.alpha_t = vForce.sqrt(self.alphasCumProd)
        self.sigma_t = vForce.sqrt(vDSP.subtract([Float](repeating: 1, count: self.alphasCumProd.count), self.alphasCumProd))
        self.lambda_t = zip(self.alpha_t, self.sigma_t).map { α, σ in log(α) - log(σ) }

        var timeSteps: [Int] = []
        timeSteps.append(contentsOf: forwardSteps.dropLast(1))
        timeSteps.append(timeSteps.last!)
        timeSteps.append(forwardSteps.last!)
        timeSteps.reverse()

        self.timeSteps = timeSteps
        self.counter = 0
        self.ets = []
        self.currentSample = nil
    }

    /// Compute a de-noised image sample and step scheduler state
    ///
    /// - Parameters:
    ///   - output: The predicted residual noise output of learned diffusion model
    ///   - timeStep: The current time step in the diffusion chain
    ///   - sample: The current input sample to the diffusion model
    /// - Returns: Predicted de-noised sample at the previous time step
    /// - Postcondition: The scheduler state is updated.
    ///   The state holds the current sample and history of model output noise residuals
    public func step(
        output: MLShapedArray<Float32>,
        timeStep t: Int,
        sample s: MLShapedArray<Float32>
    ) -> MLShapedArray<Float32> {
        
        var timeStep = t
        let stepInc = (trainStepCount / inferenceStepCount)
        var prevStep = timeStep - stepInc
        var modelOutput = output
        var sample = s

        if counter != 1 {
            if ets.count > 3 {
                ets = Array(ets[(ets.count - 3)..<ets.count])
            }
            ets.append(output)
        } else {
            prevStep = timeStep
            timeStep = timeStep + stepInc
        }

        if ets.count == 1 && counter == 0 {
            modelOutput = output
            currentSample = sample
        } else if ets.count == 1 && counter == 1 {
            modelOutput = weightedSum(
                [1.0/2.0, 1.0/2.0],
                [output,  ets[back: 1]]
            )
            sample = currentSample!
            currentSample = nil
        } else if ets.count == 2 {
            modelOutput = weightedSum(
                [3.0/2.0,      -1.0/2.0],
                [ets[back: 1], ets[back: 2]]
            )
        } else if ets.count == 3 {
            modelOutput = weightedSum(
                [23.0/12.0,    -16.0/12.0,   5.0/12.0],
                [ets[back: 1], ets[back: 2], ets[back: 3]]
            )
        } else {
            modelOutput = weightedSum(
                [55.0/24.0,    -59.0/24.0,   37/24.0,      -9/24.0],
                [ets[back: 1], ets[back: 2], ets[back: 3], ets[back: 4]]
            )
        }

        let convertedOutput = convertModelOutput(modelOutput: modelOutput, timestep: timeStep, sample: sample)
        modelOutputs.append(convertedOutput)

        let prevSample = previousSample(sample, timeStep, prevStep, modelOutput)

        counter += 1
        return prevSample
    }

    /// Convert the model output to the corresponding type the algorithm needs.
    func convertModelOutput(modelOutput: MLShapedArray<Float32>, timestep: Int, sample: MLShapedArray<Float32>) -> MLShapedArray<Float32> {
        assert(modelOutput.scalarCount == sample.scalarCount)
        let scalarCount = modelOutput.scalarCount
        let (alpha_t, sigma_t) = (self.alpha_t[timestep], self.sigma_t[timestep])

        return MLShapedArray(unsafeUninitializedShape: modelOutput.shape) { scalars, _ in
            assert(scalars.count == scalarCount)
            modelOutput.withUnsafeShapedBufferPointer { modelOutput, _, _ in
                sample.withUnsafeShapedBufferPointer { sample, _, _ in
                    for i in 0 ..< scalarCount {
                        scalars.initializeElement(at: i, to: (sample[i] - modelOutput[i] * sigma_t) / alpha_t)
                    }
                }
            }
        }
    }

    /// Compute  sample (denoised image) at previous step given a current time step
    ///
    /// - Parameters:
    ///   - sample: The current input to the model x_t
    ///   - timeStep: The current time step t
    ///   - prevStep: The previous time step t−δ
    ///   - modelOutput: Predicted noise residual the current time step e_θ(x_t, t)
    /// - Returns: Computes previous sample x_(t−δ)
    func previousSample(
        _ sample: MLShapedArray<Float32>,
        _ timeStep: Int,
        _ prevStep: Int,
        _ modelOutput: MLShapedArray<Float32>
    ) ->  MLShapedArray<Float32> {

        // Compute x_(t−δ) using formula (9) from
        // "Pseudo Numerical Methods for Diffusion Models on Manifolds",
        // Luping Liu, Yi Ren, Zhijie Lin & Zhou Zhao.
        // ICLR 2022
        //
        // Notation:
        //
        // alphaProdt       α_t
        // alphaProdtPrev   α_(t−δ)
        // betaProdt        (1 - α_t)
        // betaProdtPrev    (1 - α_(t−δ))
        let alphaProdt = alphasCumProd[timeStep]
        let alphaProdtPrev = alphasCumProd[max(0,prevStep)]
        let betaProdt = 1 - alphaProdt
        let betaProdtPrev = 1 - alphaProdtPrev

        // sampleCoeff = (α_(t−δ) - α_t) divided by
        // denominator of x_t in formula (9) and plus 1
        // Note: (α_(t−δ) - α_t) / (sqrt(α_t) * (sqrt(α_(t−δ)) + sqr(α_t))) =
        // sqrt(α_(t−δ)) / sqrt(α_t))
        let sampleCoeff = sqrt(alphaProdtPrev / alphaProdt)

        // Denominator of e_θ(x_t, t) in formula (9)
        let modelOutputDenomCoeff = alphaProdt * sqrt(betaProdtPrev)
        + sqrt(alphaProdt * betaProdt * alphaProdtPrev)

        // full formula (9)
        let modelCoeff = -(alphaProdtPrev - alphaProdt)/modelOutputDenomCoeff
        let prevSample = weightedSum(
            [Double(sampleCoeff), Double(modelCoeff)],
            [sample, modelOutput]
        )

        return prevSample
    }
}

/// Evenly spaced floats between specified interval
///
/// - Parameters:
///   - start: Start of the interval
///   - end: End of the interval
///   - count: The number of floats to return between [*start*, *end*]
/// - Returns: Float array with *count* elements evenly spaced between at *start* and *end*
func linspace(_ start: Float, _ end: Float, _ count: Int) -> [Float] {
    let scale = (end - start) / Float(count - 1)
    return (0..<count).map { Float($0)*scale + start }
}

extension Collection {
    /// Collection element index from the back. *self[back: 1]* yields the last element
    public subscript(back i: Int) -> Element {
        return self[index(endIndex, offsetBy: -i)]
    }
}

@available(iOS 16.2, macOS 13.1, *)
public extension Scheduler {
    static func convertToKarras(sigmas: [Double], stepCount: Int) -> [Double] {
        let sigmaMin: Double = sigmas.last!
        let sigmaMax = sigmas.first!
        let rho: Double = 7 // 7.0 is the value used in the paper
        let ramp: [Double] = linspace(0, 1, stepCount).map { Double($0) }
        let minInvRho: Double = pow(sigmaMin, (1 / rho))
        let maxInvRho: Double = pow(sigmaMax, (1 / rho))
        
        return ramp.map { pow(maxInvRho + $0 * (minInvRho - maxInvRho), rho) }
    }
    
    static func convertToTimesteps(sigmas: [Double], logSigmas: [Double]) -> [Double] {
        return sigmas.map { sigma in
            let logSigma = log(sigma)
            let dists = logSigmas.map { logSigma - $0 }
            
            // last index that is not negative, clipped to last index - 1
            var lowIndex = dists.reduce(-1) { partialResult, dist in
                return dist >= 0 && partialResult < dists.endIndex-2 ? partialResult + 1 : partialResult
            }
            lowIndex = max(lowIndex, 0)
            let highIndex = lowIndex + 1
            
            let low = logSigmas.count > lowIndex ? logSigmas[lowIndex] : logSigmas[0]
            let high = logSigmas.count > highIndex ? logSigmas[highIndex] : logSigmas[logSigmas.count - 1]
            
            // Interpolate sigmas
            let w = ((low - logSigma) / (low - high)).clipped(to: 0...1)
            
            // transform interpolated value to time range
            let t = (1 - w) * Double(lowIndex) + w * Double(highIndex)
            return t
        }
    }
}

@available(iOS 16.2, macOS 13.1, *)
extension Array where Element == MLShapedArray<Float32> {
    /// Compute weighted sum of shaped arrays of equal shapes
    ///
    /// - Parameters:
    ///   - weights: The weights each array is multiplied by
    /// - Returns: sum_i weights[i]*values[i]
    func weightedSum(_ weights: [Double]) -> MLShapedArray<Float32> {
        let scalarCount = self.first!.scalarCount
        assert(weights.count > 1 && self.count == weights.count)
        assert(self.allSatisfy({ $0.scalarCount == scalarCount }))

        return MLShapedArray(unsafeUninitializedShape: self.first!.shape) { scalars, _ in
            scalars.initialize(repeating: 0.0)
            for i in 0..<self.count {
                let w = Float(weights[i])
                self[i].withUnsafeShapedBufferPointer { buffer, _, _ in
                    assert(buffer.count == scalarCount)
                    // scalars[j] = w * values[i].scalars[j]
                    cblas_saxpy(Int32(scalarCount), w, buffer.baseAddress, 1, scalars.baseAddress, 1)
                }
            }
        }
    }
}
