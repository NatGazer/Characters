from PIL import Image
import numpy as np, os
T='../textures/game/'; W='work/'
os.makedirs(T,exist_ok=True)
Image.open(W+'beetle_game_albedo.png').convert('RGB').save(T+'beetle_game_albedo.jpg',quality=90,optimize=True)
Image.open(W+'beetle_game_normal.png').convert('RGB').resize((2048,2048),Image.LANCZOS).save(T+'beetle_game_normal.png',optimize=True)
a=np.asarray(Image.open(W+'beetle_game_wing_albedo.png').convert('RGB')); al=np.asarray(Image.open(W+'beetle_game_wing_alpha.png').convert('L'))
Image.fromarray(np.dstack([a,al]),'RGBA').save(T+'beetle_game_wing.png',optimize=True)
for f in sorted(os.listdir(T)): print(f, os.path.getsize(T+f)//1024,'KB')
