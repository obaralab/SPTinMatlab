function [drop, ang, dist] = spt_skel_align(skel, xy, shp, opts)
%SPT_SKEL_ALIGN  Reject detections that lie ALONG an organelle, using its skeleton.
%
%   [drop, ang, dist] = spt_skel_align(skel, xy, shp, opts)
%
% WHAT THIS CATCHES THAT THE CURVATURE TEST CANNOT. spt_ridge asks "is this response round or
% elongated" and is deliberately blind to size and to orientation. That leaves a population behind:
% a piece of bleedthrough that is elongated but not enough to fail the curvature ratio, sitting on a
% mitochondrion, smeared ALONG it. Nothing about its own shape marks it out — what marks it out is
% that its long axis agrees with the organelle underneath it.
%
% Measured on a real contaminated channel (ch3 of a dual-camera interleaved acquisition, curvature
% gate already applied at R = 2): of 1716 surviving detections, 426 were elongated (>= 1.5) and
% within 4 px of the mitochondrial skeleton. Their major axis sat a MEDIAN OF 14 DEGREES from the
% local skeleton direction, with 78 % inside 30 deg. Random orientation would give a median of 45
% and about 33 % inside 30. That alignment is the signal this uses.
%
% ALL THREE CONDITIONS ARE REQUIRED, and that is the point — each alone would take real molecules:
%   near     within alignDist px of the skeleton  (a molecule far from any organelle is not this)
%   elongated  elongation >= alignElong           (a round spot on a mitochondrion is a molecule)
%   aligned  major axis within alignDeg of the local skeleton direction
% A real single molecule sitting on a mitochondrion is round, so it fails the second. One that is
% motion-blurred is elongated along its own travel, which bears no relation to the organelle, so it
% fails the third only by coincidence — at alignDeg = 30 that coincidence costs about a third of
% blurred molecules ON the skeleton, which is why alignDeg should not be opened up much wider.
%
% INPUT
%   skel  : logical HxW skeleton of the organelle mask (bwmorph(mask,'skel',Inf))
%   xy    : Nx3 detections from spt_detect
%   shp   : Nx4 [sigMaj sigMin elong angleDeg] from spt_detect's second output
%   opts  : .alignDeg    reject within this many degrees of the skeleton. [] or <=0 disables.
%           .alignElong  minimum elongation to consider (default 1.5)
%           .alignDist   maximum distance to the skeleton, px (default 4)
% OUTPUT
%   drop  : Nx1 logical, true for detections to reject
%   ang   : Nx1 angle to the local skeleton direction, degrees (NaN where not near one)
%   dist  : Nx1 distance to the nearest skeleton pixel, px (Inf where there is no skeleton)
%
% The mask is used here to ATTRIBUTE geometry, never as a veto on position: nothing is rejected for
% merely being on a mitochondrion, which is where the biology is.

drop = false(size(xy,1),1);
ang  = nan(size(xy,1),1);
dist = inf(size(xy,1),1);
if isempty(xy), return; end

alignDeg = []; if isfield(opts,'alignDeg'), alignDeg = opts.alignDeg; end
if isempty(alignDeg) || alignDeg <= 0, return; end
minEl = 1.5; if isfield(opts,'alignElong') && ~isempty(opts.alignElong), minEl = opts.alignElong; end
maxD  = 4;   if isfield(opts,'alignDist')  && ~isempty(opts.alignDist),  maxD  = opts.alignDist;  end
if isempty(skel) || ~any(skel(:)) || isempty(shp) || size(shp,1) ~= size(xy,1), return; end

[sy, sx] = find(skel);
for i = 1:size(xy,1)
    d = hypot(sx - xy(i,1), sy - xy(i,2));
    [dm, ~] = min(d);
    dist(i) = dm;
    if dm > maxD || shp(i,3) < minEl, continue; end
    nb = d <= maxD + 2;                      % a short run of skeleton, to fit a direction to
    if nnz(nb) < 4, continue; end
    P = [sx(nb) sy(nb)];
    P = P - mean(P,1);
    [V, D] = eig(P.' * P);
    [~, ix] = max(diag(D));
    v = V(:, ix);
    skAng = mod(atan2d(v(2), v(1)), 180);    % local skeleton direction
    da = abs(skAng - shp(i,4));
    ang(i) = min(da, 180 - da);              % axes are undirected: 170 deg apart is 10 deg apart
    drop(i) = ang(i) <= alignDeg;
end
end
