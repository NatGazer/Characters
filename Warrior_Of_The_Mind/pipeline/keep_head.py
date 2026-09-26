"""Keep the approved head on a refitted body.

body_fit.py writes work/body.npz. The head the user approved is stored in work/head_approved.npz (same
topology). Vertices above the neck (z > 1.80) are taken from it, blended over the upper neck (1.75..1.80),
so body changes (build, girth) never alter the face. Output: work/body_base.npz (input of chin_sculpt.py).
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__)); W = os.path.join(HERE, 'work')

def main():
    new = dict(np.load(os.path.join(W, 'body.npz'), allow_pickle=True))
    old = np.load(os.path.join(W, 'head_approved.npz'))['V']
    t = np.clip((old[:, 2] - 1.75) / 0.05, 0, 1); w = t * t * (3 - 2 * t)
    new['V'] = new['V'] * (1 - w[:, None]) + old * w[:, None]
    np.savez(os.path.join(W, 'body_base.npz'), **new)
    print('approved head kept on', int((w > 0.99).sum()), 'vertices')

if __name__ == '__main__':
    main()
