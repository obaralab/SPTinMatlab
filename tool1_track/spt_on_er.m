function tf = spt_on_er(xy, supD)
%SPT_ON_ER  Which detections sit on the ER support, for strict geodesic linking.
%
%   tf = spt_on_er(xy, supD)
%
% xy   : Nx2 [x y] detection coords, 1-based pixels (sub-pixel; rounded onto the mask grid)
% supD : the DILATED ER support (spt_er_support) for the detections' OWN frame.
%        [] means the frame has no ER mask -> nothing is on the ER (strict mode fails closed).
%
% Returns an Nx1 logical. Out-of-image detections are false.
n = size(xy,1);
if isempty(supD) || n == 0, tf = false(n,1); return; end
[H, W] = size(supD);
xi = round(xy(:,1)); yi = round(xy(:,2));
tf = xi >= 1 & xi <= W & yi >= 1 & yi <= H;
tf(tf) = supD(sub2ind([H W], yi(tf), xi(tf)));
end
