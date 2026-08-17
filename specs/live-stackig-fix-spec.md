Technical Specification: Deep Sky Live Stacking Implementation for SkyForMac
1. Context and Problem Statement
Currently, skyformac implements a basic live stacking algorithm, but the user reports that the stacked image does not appear to "brighten" as more frames are added, and the module lacks advanced configurations.

Diagnosis of the "Not Brightening" Issue:
In deep-sky electronic assisted astronomy (EAA), stacking (averaging) frames does not inherently increase the pixel brightness values. Instead, it averages out random noise, vastly increasing the Signal-to-Noise Ratio (SNR). To make the faint deep-sky objects "brighten" and become visible, the algorithm must apply a dynamic, non-linear Histogram Stretch (Screen Transfer Function) to the stacked 32-bit/16-bit float data before rendering it to the 8-bit/10-bit screen.

This specification aims to rebuild the live stacking engine in skyformac to simulate the high-end EAA experience found in SharpCap, ASIAIR, and Jocular.

2. The Live Stacking Pipeline
Claude, please implement the following pipeline for incoming frames during a Live Stack session. Ensure high-performance processing (using Apple Accelerate, Metal, or OpenCV if already integrated into the project).

Step 1: Calibration (Preprocessing)
Before any alignment or stacking, the raw frame must be calibrated.

Dark Subtraction: Subtract a master dark frame to remove hot pixels and amp glow.

Flat Division: Divide by a master flat frame to correct vignetting and dust motes.

Algorithm: Calibrated_Pixel = (Raw_Pixel - Dark_Pixel) / Flat_Pixel

Step 2: Quality Filtering (Frame Rejection)
Do not stack bad frames (e.g., wind blur, clouds, tracking errors).

Star Detection: Run a fast star detection algorithm (e.g., finding local maximums above a background threshold).

FWHM Calculation: Calculate the Full Width at Half Maximum (FWHM) of the detected stars to measure sharpness.

Rejection Logic: If star count < Min_Stars OR FWHM > Max_FWHM_Threshold, discard the frame and do not add to the stack.

Step 3: Registration (Alignment)
The sky moves, and tracking isn't perfect. Frames must be aligned to the first valid frame (Reference Frame).

Asterism Matching: Form triangles from the brightest 15-20 stars in the current frame and match them against the reference frame's star triangles.

Transformation Matrix: Calculate the Affine Transformation Matrix (Translation + Rotation; avoid scaling unless focal length changes).

Warping: Warp the current calibrated frame using the transformation matrix.

Step 4: Integration (Stacking)
Stacking must be done in a high-bit-depth buffer (32-bit Float) to prevent clipping.

Algorithm Options:

Running Average (Default): New_Stack = ((Old_Stack * N) + New_Frame) / (N + 1)

Sigma Clipping (Advanced): Maintain a running variance. If a new pixel deviates by more than Kappa standard deviations from the mean (e.g., satellite trails), reject it.

Step 5: Dynamic Auto-Stretching (Display)
This is the critical step to solve the user's issue.

Histogram Analysis: Calculate the histogram of the 32-bit stacked buffer.

Black Point & Midtone Calculation:

Find the peak of the histogram (this represents the sky background).

Set the Black Point just to the left of the peak.

Set the White Point to protect star cores from blowing out.

Non-Linear Stretch (MTF / Arcsinh): Apply a Midtone Transfer Function (MTF) or an Arcsinh stretch to aggressively boost the faint signals (shadows/midtones) while compressing the highlights.

Example Arcsinh Stretch: Pixel_Out = (x / Black) * arcsinh(x * Stretch_Factor) / arcsinh(Stretch_Factor)

Rendering: Convert the stretched 32-bit float data to standard 8-bit RGBA for macOS UI display. Update this stretched image every time a new frame is added to the stack.

3. Required Configuration Parameters
Claude, add a configuration UI/Data Model with the following adjustable parameters:

Stacking Settings:

Stacking Method: [Average, Sigma Clipping]

Sigma Clipping Factor (Kappa): Float (Default: 3.0)

Alignment & Quality Settings:

Ignore frames if FWHM >: Float (e.g., 4.0 pixels)

Minimum Stars for Alignment: Integer (Default: 10)

Display / Stretch Settings (The "ASIAIR/Sharpcap" feel):

Stretch Aggressiveness: [Low, Medium, High] (Adjusts the MTF curve shape)

Auto Black Point Offset: Slider to adjust how dark the background sky is.

Auto Color Balance: Boolean (Aligns the peaks of the R, G, and B histograms).

4. Instructions for Claude Code
Analyze Current Code: Review skyformac's current stacking implementation. Identify where frames are accumulated and rendered.

Refactor Buffer: Ensure the internal accumulation buffer uses 32-bit floats (Float32 in Swift / CV_32F in OpenCV). If it currently uses 8-bit or 16-bit integers, rewrite it.

Implement Star Detection & Alignment: If OpenCV is available in the project, use cv::estimateRigidTransform or cv::findTransformECC. If using native Apple frameworks, utilize VNObservation for feature tracking or standard Accelerate matrix math.

Implement Auto-Stretch: Write a new Swift class/function (e.g., ImageStretcher) that takes the 32-bit float buffer, applies a dynamic non-linear stretch (MTF), and outputs an NSImage or CGImage for the UI. This must run asynchronously so the UI doesn't freeze.

Expose UI Controls: Add sliders and dropdowns in the macOS interface for the user to control the Black Point, Stretch Aggressiveness, and FWHM limits in real-time. Modifying the display stretch settings should instantly update the screen without requiring a restack of the underlying 32-bit buffer.
