"""
0002: ImprovedMotionDetector calibration max-frame exit.

Frigate's calibration requires pct_motion < 5% which never happens with a
looping pedestrian test clip (constant motion). Force calibration exit after
60 frames (12s at 5fps) so the background model has time to converge and
motion boxes reach the object detector.

Production cameras have natural quiet intervals; spike-only concern.
"""
import pathlib

f = pathlib.Path("frigate/motion/improved_motion.py")
t = f.read_text()

old = (
    "        # once the motion is less than 5% and the number of contours is < 4, assume its calibrated\n"
    "        if pct_motion < 0.05 and len(motion_boxes) <= 4:"
)
new = (
    "        # once the motion is less than 5% and the number of contours is < 4,\n"
    "        # assume its calibrated; also force exit after 60 frames for constant-motion\n"
    "        # scenes (looping test clips) so the object detector receives frames.\n"
    "        if (pct_motion < 0.05 and len(motion_boxes) <= 4) or self.frame_counter >= 60:"
)

assert old in t, "0002 patch: context not found — check Frigate version"
f.write_text(t.replace(old, new, 1))
print("0002 patch applied: motion calibration max-frame exit")
