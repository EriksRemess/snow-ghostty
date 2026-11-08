#!/usr/bin/env python3
"""Emit a block fixture on target, or check its actual GPU capture locally."""
import argparse
from pathlib import Path
import time

parser=argparse.ArgumentParser()
parser.add_argument('--capture',type=Path)
parser.add_argument('--cell-width',type=int,default=7)
parser.add_argument('--cell-height',type=int,default=17)
args=parser.parse_args()
if not args.capture:
    print('\x1b[2J\x1b[H\x1b[?25l\x1b[38;2;240;200;100m\x1b[48;2;10;20;30m'+
          ('█'*8+'\r\n')*3+'\r\n▀▄▌▐░▒▓\r\n'+
          '▖▗▘▙▚▛▜▝▞▟\r\n\x1b[0m',end='',flush=True)
    time.sleep(4)
else:
    from PIL import Image
    image=Image.open(args.capture).convert('RGB')
    w,h=args.cell_width,args.cell_height
    foreground=(240,200,100); background=(10,20,30)
    full=image.crop((8,8,8+8*w,8+3*h))
    gaps=sum(full.getpixel((x,y))!=foreground for y in range(full.height) for x in range(full.width))
    assert gaps==0,f'{gaps} pixels missing from adjacent full blocks'
    for col,top_left,top_right,bottom_left,bottom_right in (
        (0,True,True,False,False), (1,False,False,True,True),
        (2,True,False,True,False), (3,False,True,False,True),
    ):
        for px,py,ink in ((w//4,h//4,top_left),(3*w//4,h//4,top_right),
                          (w//4,3*h//4,bottom_left),(3*w//4,3*h//4,bottom_right)):
            actual=image.getpixel((8+col*w+px,8+4*h+py))
            assert actual==(foreground if ink else background),(col,px,py,actual)
    for col in (4,5,6):
        shade=image.crop((8+col*w,8+4*h,8+(col+1)*w,8+5*h))
        assert all(shade.getpixel((x,y)) in (foreground,background) for y in range(h) for x in range(w))
        assert all(any(shade.getpixel((x,y))==foreground for x in range(w)) for y in range(h))
    print('GPU capture: adjacent full blocks have zero gaps; half blocks and shades: PASS')
