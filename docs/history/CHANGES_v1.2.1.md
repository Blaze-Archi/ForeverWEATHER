# ForeverWEATHER 1.2.1

## Light catch: drops that show in the dark

With 1.2.0's low Fresnel (0.12) the beads became clear water, but on dark paint and at night they nearly disappeared: a
clear lens on a dark car shows only more dark car.

New in Vehicle droplets: **Light catch** (default 1.5, 0 to 2). Where a bead's rim mirrors something far brighter than
the paint around it, the rim mirrors more, up to 1.5 times the water's own Fresnel. So the beads catch the sky over a
dark car, and lit streets and street lamps at night, as small bright rims and specks. Where the mirrored light is no
more than about 4 times the paint (mid and light paint by day, the ground, the dark sky), the bead keeps the plain
Fresnel and stays a clear lens.

- The extra mirror only brightens, it does not tint: lamps light the rims up without turning the beads orange.
- Brightness is compared as each colour's strongest channel, so a saturated red or blue paint does not count as dark.
- It compares colours of the same frame, so it behaves the same at any exposure.
- The thin dark edge of each bead (where the water is thinnest) is a little darker with Light catch on, which outlines
  the drops.

Tested in game on a red car, by day and at night. Two things that looked wrong in that testing are not in the release:
a catch that started at 1.3 times the paint's brightness (the rims mixed with the beads' dark lens image into the
paint's own colour and the beads vanished), and a broader sky highlight (it washed out the beads' dark centres).

## Other

- Shaders: `shaders/common/postFx/rainPuddles37/` (1.2.0 used `rainPuddles31`).
- Your settings stay; Light catch starts at 1.5.
