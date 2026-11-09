"""Fixed, non-executable model allowlist. Never accept weights from the network.

Checkpoint hashes identify the individual files, not their ZIP archives. They
come from the third-party converter registry at the pinned revision below, not
signed checksums published by the weight author. See Docs/LanSuperResolution.md.
"""
from dataclasses import dataclass

SOURCE = "https://github.com/the-database/MangaJaNai/releases/tag/3.0.0"
LICENSE = "CC-BY-NC-4.0"
REGISTRY_SOURCE = ("https://github.com/imxieyi/waifu2x-ios-model-converter/blob/"
                   "68e3f51517e04433164c09d8505a409e26477905/known_models.yaml")


@dataclass(frozen=True)
class Model:
    id: str
    name: str
    file: str
    sha256: str
    architecture: str
    scale: int
    alignment: int
    maximum_pixels: int
    working_bytes_per_pixel: int

    @property
    def delivery_scales(self):
        return (2, 4) if self.scale == 4 else (2,)

    def capability(self, maximum_side, maximum_pixels):
        return {"id": self.id, "name": self.name, "sha256": self.sha256,
                "nativeScale": self.scale, "deliveryScales": list(self.delivery_scales),
                "alignment": self.alignment, "minimumSide": 64,
                "maximumSide": maximum_side,
                "maximumInputPixels": min(maximum_pixels, self.maximum_pixels),
                "precision": "float32", "mode": "fullPage", "license": LICENSE,
                "sourceURL": SOURCE}


# Limits are conservative configuration ceilings, NOT measured GPU guarantees.
MODELS = (
    Model("illustrationjanai-v3detail-hat-l-4x-float32", "HAT-L · 细节优先",
          "4x_IllustrationJaNai_V3detail_HAT_L_28k_bf16.safetensors",
          "38c00c9ff871ae292617ae1127edc150f81c4e0f8f98685e48ff9c9cd87fba3b",
          "HAT", 4, 64, 1_048_576, 40960),
    Model("illustrationjanai-v3denoise-dat2-4x-float32", "DAT2 · 去噪",
          "4x_IllustrationJaNai_V3denoise_DAT2_27k_bf16.safetensors",
          "430d5e58053be88d250b6ee2c1016a19f919baafb9b6bda0f45c14b54453fb12",
          "DAT", 4, 64, 2_097_152, 32768),
    Model("illustrationjanai-v3detail-fdat-xl-4x-float32", "FDAT-XL · 均衡",
          "4x_IllustrationJaNai_V3detail_FDAT_XL_27k_bf16.safetensors",
          "fbafec1f5a126c251de8a21e177e5a710ba2e75c7fd88fe989eb8df0508790c9",
          "FDAT", 4, 16, 4_000_000, 10240),
    Model("illustrationjanai-v3detail-fdat-m-2x-float32", "FDAT-M · 快速 2×",
          "2x_IllustrationJaNai_V3detail_FDAT_M_unshuffle_40k_fp16.safetensors",
          "8ff2ba0b970e6939f3711077f5260fcded16b8388a939a27f153c687ff5da3e0",
          "FDAT", 2, 16, 8_000_000, 2048),
)
BY_ID = {model.id: model for model in MODELS}


def get_model(model_id):
    from .protocol import ProtocolError
    if not isinstance(model_id, str) or model_id not in BY_ID:
        raise ProtocolError("Unsupported model", 409)
    return BY_ID[model_id]
