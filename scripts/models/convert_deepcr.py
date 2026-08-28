"""
Converts deepCR's ACS-WFC cosmic-ray mask model (a small 2-level U-Net, BSD-3-Clause,
https://github.com/profjsb/deepCR) from its original PyTorch checkpoint to Core ML.

This exact architecture (Conv-BatchNorm-ReLU x2 per block, matching the checkpoint's own
parameter names/shapes) predates the weight_norm-based `double_conv` in deepCR/parts.py at the
current GitHub HEAD -- reconstructed directly from the checkpoint's own state_dict keys rather
than trusting the current source, and validated by a strict (no missing/unexpected keys) state
dict load below.
"""
import coremltools as ct
import torch
import torch.nn as nn


class DoubleConv(nn.Module):
    def __init__(self, in_ch, out_ch):
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(in_ch, out_ch, 3, padding=1),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
            nn.Conv2d(out_ch, out_ch, 3, padding=1),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
        )

    def forward(self, x):
        return self.conv(x)


class Inconv(nn.Module):
    def __init__(self, in_ch, out_ch):
        super().__init__()
        self.conv = DoubleConv(in_ch, out_ch)

    def forward(self, x):
        return self.conv(x)


class Down(nn.Module):
    def __init__(self, in_ch, out_ch):
        super().__init__()
        self.mpconv = nn.Sequential(nn.MaxPool2d(2), DoubleConv(in_ch, out_ch))

    def forward(self, x):
        return self.mpconv(x)


class Up(nn.Module):
    def __init__(self, in_ch, out_ch):
        super().__init__()
        self.up = nn.ConvTranspose2d(in_ch, out_ch, 2, stride=2)
        self.conv = DoubleConv(in_ch, out_ch)

    def forward(self, x1, x2):
        x1 = self.up(x1)
        x = torch.cat([x2, x1], dim=1)
        return self.conv(x)


class Outconv(nn.Module):
    def __init__(self, in_ch, out_ch):
        super().__init__()
        self.conv = nn.Conv2d(in_ch, out_ch, 1)

    def forward(self, x):
        return self.conv(x)


class UNet2Sigmoid(nn.Module):
    def __init__(self, n_channels, n_classes, hidden=32):
        super().__init__()
        self.inc = Inconv(n_channels, hidden)
        self.down1 = Down(hidden, hidden * 2)
        self.up8 = Up(hidden * 2, hidden)
        self.outc = Outconv(hidden, n_classes)

    def forward(self, x):
        x1 = self.inc(x)
        x2 = self.down1(x1)
        x = self.up8(x2, x1)
        x = self.outc(x)
        return torch.sigmoid(x)


def convert(checkpoint_path, output_path):
    raw = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    state_dict = raw.state_dict() if hasattr(raw, "state_dict") else raw
    # The checkpoint's own keys are prefixed "module." (from PyTorch's DataParallel wrapper at
    # training time) -- strip it to match this plain (non-wrapped) module's own key names.
    state_dict = {k.replace("module.", "", 1): v for k, v in state_dict.items()}

    model = UNet2Sigmoid(1, 1, hidden=32)
    missing, unexpected = model.load_state_dict(state_dict, strict=True)
    assert not missing and not unexpected, f"key mismatch: missing={missing} unexpected={unexpected}"
    model.eval()

    example_input = torch.rand(1, 1, 256, 256)
    traced = torch.jit.trace(model, example_input)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image", shape=(1, 1, ct.RangeDim(64, 4096, default=256), ct.RangeDim(64, 4096, default=256)),
            color_layout=ct.colorlayout.GRAYSCALE, scale=1 / 255.0,
        )],
        outputs=[ct.TensorType(name="mask")],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.author = "profjsb/deepCR (BSD-3-Clause) -- converted for Skyformac"
    mlmodel.license = "BSD-3-Clause (see LICENSE.md)"
    mlmodel.short_description = "Cosmic-ray pixel mask prediction (ACS-WFC), from deepCR's UNet2Sigmoid."
    mlmodel.save(output_path)
    print(f"Saved {output_path}")

    # Sanity check: a real forward pass through the saved Core ML model should produce a
    # sigmoid-ranged (0...1) mask, matching the PyTorch model's own output on the same input.
    import numpy as np
    from PIL import Image
    test_arr = (np.random.rand(256, 256) * 255).astype("uint8")
    test_img = Image.fromarray(test_arr, mode="L")
    coreml_out = mlmodel.predict({"image": test_img})["mask"]
    with torch.no_grad():
        torch_out = model(torch.from_numpy(test_arr.astype("float32") / 255.0).unsqueeze(0).unsqueeze(0)).numpy()
    diff = abs(coreml_out - torch_out).max()
    print(f"max abs diff CoreML vs PyTorch: {diff}")
    print(f"CoreML output range: [{coreml_out.min()}, {coreml_out.max()}]")
    assert diff < 0.02, f"CoreML output diverges from PyTorch by {diff}"


if __name__ == "__main__":
    convert("learned_models/mask/ACS-WFC.pth", "/tmp/DeepCRCosmicRayMask.mlpackage")
