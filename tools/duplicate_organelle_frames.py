# @File(label="Organelle folder (ER or mito segmentations)", style="directory") segDir
# @File(label="SPT folder (the movies to match)", style="directory") sptDir
# @File(label="Output folder", style="directory") outDir
# @String(label="Strip from BOTH names (regex; e.g. _VAPB or _ch24)", value="", required=false) stripRe
# @String(label="SPT name suffix (regex, no $)", value="_spt\\d*") sptSuffix
# @String(label="Organelle name suffix (regex, no $)", value="_(2_TA_BC|3_TA_BC|er_mip|mito_mip|ch1_mito|er|mito)") segSuffix
# @Integer(label="Repeat each organelle frame N times (0 = derive per cell)", value=0) forceN
# @Boolean(label="Dry run (report only, write nothing)", value=True) dryRun
#
# duplicate_organelle_frames.py — Fiji / ImageJ2 Jython
#
# Repeat each page of an ER or mitochondrial segmentation stack N times, so it has one page per SPT
# movie frame. Run it from Fiji: Plugins > Scripting > Script Editor, set the language to Python
# (Jython), open this file, Run.
#
# WHY. When the organelle channel is imaged at a lower rate than the particle channel, its stack is
# shorter than the movie. Tool 1's DETECTION handles that with an index map ("1 organelle frame
# covers N SPT frames"), but every VIEWER in the suite — Tool 1's track player, Tool 2's Import &
# Curate overlay, Tool 3's picker and its Sites/Dwell overlays — reads the organelle stack
# page-for-page. Handed a half-length stack they either clamp to the last page (drawing a stale
# outline as though it were current) or stop drawing once it runs out. Materialising the repeats up
# front sidesteps all of that: every tool then sees one organelle page per movie frame.
#
# WHAT IT DOES NOT DO. It does not interpolate. Page k is repeated verbatim, so movie frames
# N*(k-1)+1 .. N*k all carry the organelle outline as measured for that exposure. That is exactly
# what the index map did, made explicit on disk — no new information is invented.
#
# COST. Output is N times the input size. Check free space before writing; the dry run reports the
# page counts it would produce.
#
# ============================ HOW FILES ARE PAIRED ============================
# Both names are reduced to a CELL KEY and matched on it. The reduction, in order:
#
#   1. drop the extension                    HVK-..._Plate1_ch24_spt.tif -> HVK-..._Plate1_ch24_spt
#   2. drop an ilastik export token          ..._Simple Segmentation     -> ...
#   3. drop the STRIP regex, anywhere        _ch24  ->  HVK-..._Plate1_spt
#   4. drop the channel SUFFIX, at the end   _spt\d* ->  HVK-..._Plate1
#
# Step 3 is the one that does the work when one side carries a token the other does not — '_VAPB' on
# segmentations, '_ch24' on SPT movies. It runs BEFORE step 4, so a name like '..._ch24_spt' loses
# '_ch24' first and then still ends in '_spt' for the suffix rule to strip.
#
# NOTE ON THE SUFFIX PATTERNS. The leading underscore is supplied by the pattern itself, so the
# alternatives inside the group are written WITHOUT one: '..|er|mito)' already means '_er' or
# '_mito'. Writing '_mito' inside the group would ask for '__mito' and match nothing.
#
# ---------------------------- WORKED EXAMPLES --------------------------------
# Two real conventions, both handled by the STRIP field alone — no code editing.
#
# (A) the SEGMENTATION carries a token the movie does not      strip = _VAPB
#
#       organelle  250408_VAPB_WT_011.tiff
#       SPT        250408_WT_011_spt12.tif
#
#       organelle  250408_VAPB_WT_011   --strip-->  250408_WT_011    --segSuffix-->  250408_WT_011
#       SPT        250408_WT_011_spt12  --strip-->  250408_WT_011_spt12 --sptSuffix->  250408_WT_011
#                                                                                keys MATCH
#
# (B) the MOVIE carries a channel token the segmentation does not    strip = _ch24
#
#       organelle  HVK-3C-NoLigand-Baseline_Plate1_mito.tiff
#       SPT        HVK-3C-NoLigand-Baseline_Plate1_ch24_spt.tif
#
#       organelle  ..._Plate1_mito      --strip-->  ..._Plate1_mito  --segSuffix-->  ..._Plate1
#       SPT        ..._Plate1_ch24_spt  --strip-->  ..._Plate1_spt   --sptSuffix-->  ..._Plate1
#                                                                                keys MATCH
#
#       Note the ORDER: strip runs first, so '_ch24' goes even though it sits in the MIDDLE of the
#       name, and what is left still ends in '_spt' for the suffix rule to take.
#
# (C) nothing extra on either side                              strip = (blank)
#
#       organelle  cellA_mito.tif  -->  cellA          SPT  cellA_spt.tif  -->  cellA
#
# ------------------------- WORKING OUT YOUR OWN ------------------------------
#   1. Take one matching pair of names and drop the extensions.
#   2. The CELL KEY is the part they share — the well/cell identifier.
#   3. Anything extra at the END of the SPT name goes in sptSuffix   (e.g. _spt\d*, _ch\d+_spt).
#   4. Anything extra at the END of the organelle name goes in segSuffix.
#   5. Anything extra in the MIDDLE of either name goes in strip     (e.g. _VAPB, _ch24).
#   6. Run with Dry run ticked and read the 'paired' column before writing anything.
#
#   ADDING TO segSuffix: the leading underscore is supplied by the pattern, so alternatives go in
#   WITHOUT one — '(...|er|mito)' already means '_er' or '_mito'. Writing '_mito' inside the group
#   asks for '__mito' and matches nothing. To accept '_lyso' as well, use
#       _(2_TA_BC|3_TA_BC|er_mip|mito_mip|ch1_mito|er|mito|lyso)
#
#   Regexes are Python's: \d = a digit, \d* = zero or more, | = or, () = a group. A literal dot
#   needs escaping (\.), but plain names like _ch24 need nothing.
#
# FALLBACK. If the rules leave a segmentation unmatched, it is paired with the SPT file sharing the
# longest common prefix, provided that prefix is long enough and unambiguous. The log marks those
# 'by prefix' so you can check them in the dry run before trusting them. It is a safety net for a
# convention the fields do not describe — prefer setting the fields correctly.

import os
import re
from ij import IJ, ImagePlus, ImageStack
from ij.io import FileSaver

ILASTIK = re.compile(r'[ _](Probabilities|Simple[ _]Segmentation|Segmentation|Uncertainty|Object[ _]Predictions)$', re.IGNORECASE)
EXT = re.compile(r'\.(tif|tiff)$', re.IGNORECASE)

MIN_PREFIX = 8          # a shorter shared prefix than this is not evidence of anything


def base_of(name):
    """File name without extension or ilastik export token."""
    return ILASTIK.sub('', EXT.sub('', name))


def key_of(name, strip, suffix_re):
    """Cell key — the same reductions spt_match.m applies, in the same order."""
    k = base_of(name)
    if strip:
        k = re.sub(strip, '', k, flags=re.IGNORECASE)
    return suffix_re.sub('', k)


def list_tiffs(d):
    return sorted(f for f in os.listdir(d) if EXT.search(f))


def common_prefix_len(a, b):
    a, b = a.lower(), b.lower()
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def page_count(path):
    """Pages without loading the pixels: opening the stack reads every page, and these are big.

    getTiffFileInfo returns one FileInfo PER IFD for most writers, but a stack ImageJ wrote as one
    contiguous block comes back as a SINGLE FileInfo carrying nImages instead. Reading len() alone
    reported 1 page for every such movie — which then made every ratio look fractional and skipped
    the whole run. Take nImages when it is set, and fall back to opening the stack if neither says
    anything sensible.
    """
    from ij.io import Opener
    try:
        info = Opener().getTiffFileInfo(path)
        if info:
            n = len(info)
            try:
                nim = int(info[0].nImages)
            except Exception:
                nim = 0
            if n == 1 and nim > 1:
                return nim
            if n >= 1:
                return n
    except Exception:
        pass
    imp = IJ.openImage(path)          # last resort: reads the pixels
    if imp is None:
        return 0
    n = imp.getStackSize()
    imp.close()
    return n


def pair_files(seg_files, spt_files, strip, spt_re, seg_re):
    """[(segFile, sptFile or None, how)] — rule-based first, then longest-common-prefix."""
    spt_by_key = {}
    for f in spt_files:
        spt_by_key.setdefault(key_of(f, strip, spt_re), f)

    pairs = []
    unmatched_seg = []
    used = set()
    for sf in seg_files:
        k = key_of(sf, strip, seg_re)
        if k in spt_by_key:
            pairs.append((sf, spt_by_key[k], 'by key "%s"' % k))
            used.add(spt_by_key[k])
        else:
            unmatched_seg.append(sf)

    spare = [f for f in spt_files if f not in used]
    for sf in unmatched_seg:
        sb = base_of(sf)
        scored = sorted(((common_prefix_len(sb, base_of(f)), f) for f in spare), reverse=True)
        if not scored or scored[0][0] < MIN_PREFIX:
            pairs.append((sf, None, 'no match'))
            continue
        # Ambiguous when two candidates share the same prefix length — pairing arbitrarily there
        # would silently duplicate the wrong organelle onto a cell.
        if len(scored) > 1 and scored[1][0] == scored[0][0]:
            pairs.append((sf, None, 'ambiguous prefix (%d chars, %d candidates)'
                          % (scored[0][0], sum(1 for s in scored if s[0] == scored[0][0]))))
            continue
        pairs.append((sf, scored[0][1], 'by prefix (%d chars)' % scored[0][0]))
        spare.remove(scored[0][1])
    return pairs


def run():
    segD, sptD, outD = str(segDir), str(sptDir), str(outDir)
    strip = str(stripRe).strip()
    n_force = int(forceN)
    try:
        spt_re = re.compile(str(sptSuffix) + '$', re.IGNORECASE)
        seg_re = re.compile(str(segSuffix) + '$', re.IGNORECASE)
    except Exception, e:
        IJ.log('Bad suffix pattern: %s' % e)
        return

    seg_files = list_tiffs(segD)
    spt_files = list_tiffs(sptD)
    if not seg_files:
        IJ.log('No TIFFs in the organelle folder — nothing to do.')
        return
    if not spt_files:
        IJ.log('No TIFFs in the SPT folder — nothing to match against.')
        return

    IJ.log('=== duplicate_organelle_frames ===')
    IJ.log('strip="%s"  sptSuffix="%s"  segSuffix="%s"' % (strip, sptSuffix, segSuffix))
    IJ.log('%-44s %7s %7s %4s  %-26s %s' % ('organelle file', 'seg', 'spt', 'N', 'paired', 'action'))

    pairs = pair_files(seg_files, spt_files, strip, spt_re, seg_re)
    n_by_key = sum(1 for _, _, how in pairs if how.startswith('by key'))
    total_out = 0
    done = 0
    for sf, mf, how in pairs:
        segPath = os.path.join(segD, sf)
        nSeg = page_count(segPath)

        if mf is None:
            IJ.log('%-44s %7d %7s %4s  %-26s %s' % (sf, nSeg, '-', '-', how, 'SKIPPED'))
            continue

        nSpt = page_count(os.path.join(sptD, mf))

        if n_force > 0:
            n = n_force
        elif nSeg < 1 or nSpt < 1:
            IJ.log('%-44s %7d %7d %4s  %-26s %s' % (sf, nSeg, nSpt, '-', how, 'UNREADABLE'))
            continue
        elif nSpt % nSeg != 0:
            # Not a whole ratio: the stacks are not in a rate relationship, and repeating a
            # fractional number of times would smear one exposure over a varying number of frames.
            IJ.log('%-44s %7d %7d %4s  %-26s %s' %
                   (sf, nSeg, nSpt, '-', how, 'SKIPPED: %d/%d not a whole ratio' % (nSpt, nSeg)))
            continue
        else:
            n = nSpt // nSeg

        if n == 1:
            IJ.log('%-44s %7d %7d %4d  %-26s %s' % (sf, nSeg, nSpt, n, how, 'already matched'))
            continue

        if dryRun:
            IJ.log('%-44s %7d %7d %4d  %-26s %s' %
                   (sf, nSeg, nSpt, n, how, 'would write %d pages' % (nSeg * n)))
            total_out += nSeg * n
            continue

        imp = IJ.openImage(segPath)
        if imp is None:
            IJ.log('%-44s %7d %7d %4d  %-26s %s' % (sf, nSeg, nSpt, n, how, 'COULD NOT OPEN'))
            continue
        src = imp.getStack()
        dst = ImageStack(imp.getWidth(), imp.getHeight())
        for p in range(1, src.getSize() + 1):
            ip = src.getProcessor(p)
            for _ in range(n):
                # duplicate() per copy: sharing one processor would make every repeat the same
                # object, so a later write through one of them would change all of them.
                dst.addSlice(src.getSliceLabel(p), ip.duplicate())
        out = ImagePlus(imp.getTitle(), dst)
        out.setCalibration(imp.getCalibration())
        ok = FileSaver(out).saveAsTiff(os.path.join(outD, sf))
        out.close()
        imp.close()
        IJ.log('%-44s %7d %7d %4d  %-26s %s' %
               (sf, nSeg, nSpt, n, how, ('written (%d pages)' % (nSeg * n)) if ok else 'WRITE FAILED'))
        if ok:
            total_out += nSeg * n
            done += 1

    IJ.log('---')
    if n_by_key == 0 and pairs:
        # Everything fell through to the prefix fallback. That can still be right, but it means the
        # strip/suffix fields do not describe these names — and a coincidence of prefixes is a thin
        # thing to duplicate gigabytes on.
        IJ.log('NOTE: nothing matched by the naming rules — every pair came from the prefix fallback.')
        IJ.log('      Set "Strip from BOTH names" to the token one side carries and the other does not.')
        IJ.log('      e.g. names like NAME_ch24_spt.tif against NAME_mito.tiff need strip = _ch24')
    if dryRun:
        IJ.log('DRY RUN — nothing written. %d pages would be produced.' % total_out)
        IJ.log('Check the "paired" column, then untick Dry run. Output is N x the input size.')
    else:
        IJ.log('%d file(s) written to %s (%d pages).' % (done, outD, total_out))
    IJ.log('Then point Tool 1 at the OUTPUT folder as er_seg / mito_seg and leave')
    IJ.log('"1 organelle frame covers" on auto — it resolves to 1 once the lengths match.')


run()
