//
//  PredictionType.swift
//  
//
//  Created by Guillermo Cique Fernández on 20/5/23.
//

import Foundation

/// Prediction type of the scheduler function
public enum PredictionType: String, Decodable {
    /// Predicting the noise of the diffusion process
    case epsilon
    /// Directly predicts the noisy sample
    case sample
    /// See section 2.4 https://imagen.research.google/video/paper.pdf
    case vPrediction = "v_prediction"
}
