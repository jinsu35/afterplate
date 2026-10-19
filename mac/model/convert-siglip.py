"""Download google/siglip-base-patch16-224 (Apache 2.0) from Hugging Face and
convert its image tower to Core ML at mac/Afterplate/SigLIPImage.mlpackage.

The text side is not needed: apple-prompts.json already holds the sentence
embeddings, made with the same model. Run through ./get-model.sh, which sets
up the Python packages this was tested with.
"""
import os
import numpy as np
import torch
import transformers
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops as torch_ops

# coremltools casts a one-element array with int(array), which numpy 2 refuses
# ("only 0-dimensional arrays can be converted to Python scalars"). Cast its
# item instead.
_original_cast = torch_ops._cast
def _cast(context, node, dtype, dtype_name):
    inputs = torch_ops._get_inputs(context, node, expected=1)
    x = inputs[0]
    if x.can_be_folded_to_const() and not isinstance(x.val, dtype) and hasattr(x.val, "item"):
        context.add(mb.const(val=dtype(x.val.item()), name=node.name), node.name)
        return
    _original_cast(context, node, dtype, dtype_name)
torch_ops._cast = _cast

MODEL = "google/siglip-base-patch16-224"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("AFTERPLATE_MODEL_OUT") or os.path.join(HERE, "..", "Afterplate", "SigLIPImage.mlpackage")

model = transformers.AutoModel.from_pretrained(MODEL, attn_implementation="eager").eval()

class ImageTower(torch.nn.Module):
    def __init__(self, vision):
        super().__init__()
        self.vision = vision
    def forward(self, pixels):
        return self.vision(pixel_values=pixels).pooler_output

traced = torch.jit.trace(ImageTower(model.vision_model).eval(), torch.rand(1, 3, 224, 224) * 2 - 1)
# SigLIP's preprocessing: the photo squeezed to 224×224, pixels to [-1, 1].
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1 / 127.5, bias=[-1, -1, -1],
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.short_description = f"SigLIP image tower ({MODEL}, Apache 2.0)"
mlmodel.license = "Apache-2.0"
mlmodel.save(OUT)

# The sentence embeddings in apple-prompts.json must come from this same model.
import json
prompts = json.load(open(os.path.join(HERE, "..", "Afterplate", "apple-prompts.json")))
processor = transformers.AutoProcessor.from_pretrained(MODEL)
with torch.no_grad():
    text = model.get_text_features(**processor(text=prompts["subject"][:1], padding="max_length",
                                               max_length=64, return_tensors="pt"))
text = torch.nn.functional.normalize(text, dim=-1).numpy()[0]
stored = np.array(prompts["subject_embeddings"][0])
print(f"saved {os.path.normpath(OUT)}; prompt embeddings match the model: {float(text @ stored):.4f}")
