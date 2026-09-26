"""Stage 0b: body-pose and face landmarks on the reference images (MediaPipe Tasks).
Writes pipeline/work/landmarks.json and annotated debug images."""
import glob, os, json
import numpy as np, cv2
import mediapipe as mp
from mediapipe.tasks import python as mpt
from mediapipe.tasks.python import vision

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
W = os.path.join(HERE, 'work'); MODELS = os.environ.get('MP_MODELS', '/opt/assets/mp')
pose = vision.PoseLandmarker.create_from_options(vision.PoseLandmarkerOptions(
    base_options=mpt.BaseOptions(model_asset_path=f'{MODELS}/pose_landmarker_heavy.task'), num_poses=1))
face = vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
    base_options=mpt.BaseOptions(model_asset_path=f'{MODELS}/face_landmarker.task'), num_faces=1,
    output_facial_transformation_matrixes=True))
res = {}
for f in sorted(glob.glob(os.path.join(ROOT, 'Reference-Images', '*.png'))):
    name = os.path.splitext(os.path.basename(f))[0]
    bgr = cv2.imread(f); h, w = bgr.shape[:2]
    img = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
    r = {}
    p = pose.detect(img)
    if p.pose_landmarks:
        r['pose'] = [[l.x * w, l.y * h, l.z * w, l.visibility] for l in p.pose_landmarks[0]]
        r['pose_world'] = [[l.x, l.y, l.z] for l in p.pose_world_landmarks[0]]
    # face: crop the head region at 4x for precision
    if 'pose' in r:
        hp = np.array(r['pose'][:11])[:, :2]; c = hp.mean(0)
    else:
        c = np.array([w / 2, 110.])
    S = 260; x0 = int(np.clip(c[0] - S / 2, 0, w - S)); y0 = int(np.clip(c[1] - S / 2, 0, h - S))
    crop = cv2.resize(bgr[y0:y0 + S, x0:x0 + S], (S * 3, S * 3), interpolation=cv2.INTER_CUBIC)
    fr = face.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(crop, cv2.COLOR_BGR2RGB)))
    if fr.face_landmarks:
        pts = np.array([[x0 + l.x * S, y0 + l.y * S, l.z * S] for l in fr.face_landmarks[0]])
        r['face'] = pts.tolist()
        r['face_matrix'] = np.array(fr.facial_transformation_matrixes[0]).tolist()
    res[name] = r
    dbg = bgr.copy()
    for x, y, *_ in r.get('pose', []): cv2.circle(dbg, (int(x), int(y)), 5, (0, 255, 255), -1)
    for x, y, _ in r.get('face', []): cv2.circle(dbg, (int(x), int(y)), 1, (255, 255, 0), -1)
    cv2.imwrite(os.path.join(W, f'lm_{name}.jpg'), dbg)
    print(name, 'pose' in r, 'face' in r)
json.dump(res, open(os.path.join(W, 'landmarks.json'), 'w'))
import sys

json.dump(res, open(os.path.join(W, 'landmarks.json'), 'w'))
