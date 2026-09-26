# geodesic breakpoints from claw tips (mm): [claw|t2, t2|t1, t1|tibia(ankle), tibia|femur(knee), femur|body(hip)]
LEGBP={'FL':[3.5,7.0,10.5,24.5,34.5],'FR':[3.5,7.0,10.5,24.5,34.0],
       'ML':[3.8,7.5,11.0,23.5,30.5],'MR':[4.0,8.0,12.3,23.0,30.0],
       'HL':[4.5,9.5,14.8,28.5,33.0],'HR':[4.5,9.0,13.8,28.8,33.0]}
SEGS=['claw','tarsus2','tarsus1','tibia','femur']
ANTBP={'AL':[4.1,6.9],'AR':[4.2,6.8]}   # club|stalk, stalk|head
# femur bands lying on the ventral body: (A xy, B xy, halfwidth)
FEMBAND={'HR':((13.5,16.5),(8.3,3.0),3.0),'HL':((13.8,-16.3),(8.3,-3.2),3.0),
         'MR':((-1.2,16.0),(-2.6,4.0),2.0),'ML':((0.3,-15.0),(-2.6,-3.5),2.2),
         'FR':((-9.8,9.5),(-9.0,5.0),2.0),'FL':((-10.0,-9.5),(-9.2,-5.0),2.0)}
