function supD = spt_er_support(sup)
%SPT_ER_SUPPORT  The ER support that strict geodesic linking tests against: the mask dilated 1 px.
%
%   supD = spt_er_support(sup)
%
% The 1 px slack tolerates a small SPT/ER channel registration offset (a spot 1 px outside the
% segmented ER is still "on" it; 2 px is not). This is the SINGLE definition of the ER support —
% the strict cost function, the detection pre-filter and the gap-close reachability test all go
% through here, so they can never drift apart.
%
% An empty/missing mask returns [], which every caller must read as "no ER for this frame" and
% therefore FORBID linking (strict mode fails closed), never as "no constraint".
if isempty(sup), supD = []; return; end
supD = imdilate(logical(sup), strel('disk',1));
end
