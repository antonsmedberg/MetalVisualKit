# Third-party notices

## Apple scene-depth sample

`Sources/MetalVisualKit/PointCloud/PointCloudMath.swift` follows the camera-orientation derivation from Apple’s **Visualizing a Point Cloud Using Scene Depth** sample code. The implementation in this package is adapted to its own renderer and public API.

The sample carries this notice:

> Copyright © 2020 Apple Inc.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Apple `capturedImage` conversion matrix

`cameraColour()` in `Sources/MetalVisualKit/PointCloud/PointCloudShaders.metal`
uses the full-range YCbCr-to-sRGB matrix published in Apple's documentation for
[`ARFrame.capturedImage`](https://developer.apple.com/documentation/arkit/arframe/capturedimage).
Apple documents it as the conversion required for ARKit's full-range ITU-R
BT.601 capture, per ITU-T T.871. The coefficients are the standard ones for that
transform; the surrounding shader is this package's own.
