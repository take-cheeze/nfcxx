# | needs a set on both sides: with a list the reference raises a TypeError that names __or__, also for |=.
s = {1}
s |= [2]
result = s
