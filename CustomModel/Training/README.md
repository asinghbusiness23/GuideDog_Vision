# Custom Model Training Source

The PyTorch source used to train BlindGuideNav, the custom 55 class object detection model that ships with GuideDog. Stored here as a reference, not wired into either the iOS app or the website. Both of those load the precompiled artifacts (`CustomModel/BlindGuideNav.mlpackage` for the app, the same model for the website) and never touch the training code.

## What's in here

`ObjectDetection/Model/` holds the full PyTorch pipeline:

| File | Purpose |
|---|---|
| `model.py` | YOLO style network: convolutional backbone, neck, detection head |
| `loss.py` | YOLO loss function used during training |
| `dataset.py` | Dataset loader and augmentation pipeline |
| `train.py` | Training loop with checkpointing |
| `inference.py` | Run inference + draw bounding boxes |
| `utils.py` | IoU, non max suppression, mAP, decoding |
| `config.py` | Hyperparameters |
| `export_yolo_onnx.py` | Export trained `.pth` checkpoint to ONNX |
| `data_visualizer.py` / `data_debug.py` / `DatasetCheck.py` | Dataset inspection tools |
| `requirements.txt` | Python dependencies |
| `yolo.onnx` | Exported ONNX model |
| `final_model.pth` | Trained PyTorch weights |
| `dataset_sample.png` / `gt_visualization.png` / `result.jpg` | Sample visualizations |

`ObjectDetection/Data/data.yaml` holds the class list and split configuration.

## What's not in here (intentionally)

The raw training images (400+ MB) are not committed. They live outside the repo to keep the clone size sane. If anyone needs to retrain from scratch, the dataset itself has to be sourced separately and dropped into `ObjectDetection/Data/` following the layout described in `data.yaml`.

Also excluded:

- Virtual environments (`venv/`, `onnx_env/`)
- The TensorFlow / TFJS / web exports (rebuildable from `yolo.onnx`)
- Pre cached `__pycache__` and `.DS_Store` files

## Reproducing the model

The full pipeline runs locally with `pip install -r ObjectDetection/Model/requirements.txt`. Drop a labeled dataset into `ObjectDetection/Data/` matching the layout `data.yaml` expects, then `python train.py`. Training time depends on hardware. The provided checkpoint was trained on a single GPU over several epochs.

## Why this folder is not loaded by either app

The mobile and web clients run the compiled artifact (CoreML for iOS, ONNX for web), not Python. Keeping the source separate makes the production bundles small, keeps the training environment isolated from the shipping app, and lets the model evolve without forcing a corresponding app release.
