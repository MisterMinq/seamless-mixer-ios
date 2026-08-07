import Foundation
import Accelerate

/// Thin wrapper around vDSP's packed-real FFT (`vDSP_fft_zrip`), producing a
/// magnitude spectrum for one windowed frame at a time. Isolated in its own
/// file because this is the single most likely place for a subtle bug: real
/// FFT packing/scaling conventions (how the Nyquist bin gets folded into
/// `imagp[0]`, the 1/N vs 2/N scaling factor) are notoriously easy to get
/// wrong and hard to catch without running it against a signal of known
/// frequency.
///
/// **Not compiled or tested.** Validate before trusting `AudioFeatureExtractor`'s
/// output: feed this a synthesized pure sine tone (see
/// `AudioFeatureExtractorTests.testSpectralCentroidOfPureToneMatchesItsFrequency`)
/// and confirm the magnitude spectrum peaks at the expected bin. If it
/// doesn't, this file — not the chroma/tempo logic built on top of it — is
/// almost certainly where the bug is.
final class FFTProcessor {
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    init(fftSize: Int) {
        precondition(fftSize > 0 && (fftSize & (fftSize - 1)) == 0, "fftSize must be a power of two")
        self.fftSize = fftSize
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("FFTProcessor: vDSP_create_fftsetup failed for fftSize \(fftSize)")
        }
        self.fftSetup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// - Parameter windowedFrame: exactly `fftSize` samples, already windowed
    ///   (e.g. Hann) by the caller.
    /// - Returns: magnitude spectrum, length `fftSize / 2` (bins 0...Nyquist-1).
    func magnitudeSpectrum(of windowedFrame: [Float]) -> [Float] {
        precondition(windowedFrame.count == fftSize)

        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        var magnitudesSquared = [Float](repeating: 0, count: fftSize / 2)
        var frame = windowedFrame

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                // Pack the real signal into interleaved-complex form, then into split form.
                frame.withUnsafeMutableBytes { rawFrame in
                    let complexPtr = rawFrame.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudesSquared, 1, vDSP_Length(fftSize / 2))
            }
        }

        // vDSP_fft_zrip's packed real-FFT output is scaled by a factor of 2
        // relative to an unpacked complex FFT of the same signal; taking the
        // square root of the magnitude-squared output and normalizing by
        // fftSize keeps values in a stable, comparable range across frame
        // sizes. This scaling has not been cross-checked against librosa's
        // output on a real signal — treat absolute magnitude values as
        // relative/comparable to each other, not as calibrated absolute
        // amplitudes, until validated.
        return magnitudesSquared.map { sqrt($0) / Float(fftSize) }
    }
}
