function P = cs_dwell_primitives()
%CS_DWELL_PRIMITIVES  Residence-time primitives, lifted VERBATIM from spt_pipeline_app.m.
%
%   P = cs_dwell_primitives()  ->  struct of function handles:
%       P.inside(x,y,bx,by)        logical mask of localizations inside a boundary
%       P.runs(inside,fr,dt)       maximal runs of consecutive INSIDE locs -> [entryF exitF dwell]
%       P.merge(iv)                merge overlapping [entryF exitF] rows
%       P.classify(iv,frv)         RESIDENT/ENTERS/EXITS/ENTERS+EXITS + arrival/departure frames
%
% These encode load-bearing conventions (inpolygon on refCentre-relative coords; dwell =
% (exitFrame-entryFrame+1)*dt frame-span accounting; overlap merge to dedup overlapping sites)
% and MUST NOT be re-derived. Kept byte-identical to the paper suite's Dwell tab.
P = struct('inside',@csInsideMask,'runs',@runsToEvents,'merge',@mergeIntervals,'classify',@classifyInside);
end

function m = csInsideMask(x,y,bx,by)     % logical mask of localizations inside the boundary
ok=isfinite(x)&isfinite(y); m=false(size(x)); m(ok)=inpolygon(x(ok),y(ok),bx,by);
end

function ev = runsToEvents(inside,fr,dt)  % maximal runs of consecutive INSIDE localizations -> [entryFrame exitFrame dwell]
ev=zeros(0,3); d=diff([false; inside(:); false]); s=find(d==1); e=find(d==-1)-1;
for ii=1:numel(s)
    a=s(ii); b=e(ii); ev(end+1,:)=[fr(a) fr(b) (fr(b)-fr(a)+1)*dt]; %#ok<AGROW>
end
end

function mg = mergeIntervals(iv)          % merge overlapping [entryFrame exitFrame] rows (dedup overlapping CS)
mg=zeros(0,2); if isempty(iv), return; end
iv=sortrows(iv,1); cur=iv(1,1:2);
for r=2:size(iv,1)
    if iv(r,1) <= cur(2), cur(2)=max(cur(2),iv(r,2));   % overlap -> extend
    else, mg(end+1,:)=cur; cur=iv(r,1:2); end            %#ok<AGROW>
end
mg(end+1,:)=cur;
end

function [cls,entF,exF] = classifyInside(iv,frv)
% Classify a track's residence in ONE contact site from its INSIDE mask, evaluated only at real
% (finite) localizations in frame order. RESIDENT (never crosses) / ENTERS (a 0->1) / EXITS
% (a 1->0) / ENTERS+EXITS (both). entF = every arrival frame; exF = every departure frame.
cls='—'; entF=[]; exF=[]; iv=logical(iv(:)); frv=frv(:);
if isempty(iv) || ~any(iv), return; end            % never inside -> not truly associated
if all(iv), cls='RESIDENT'; return; end            % inside throughout observed dwell (no crossings)
du=diff(double(iv)); up=find(du==1); dn=find(du==-1);
entF=frv(up+1);        % each 0->1 -> arrival (first inside frame of that episode)
exF =frv(dn);          % each 1->0 -> departure (last inside frame before leaving)
hasIn=~isempty(up); hasOut=~isempty(dn);
if hasIn && hasOut, cls='ENTERS+EXITS';
elseif hasIn,       cls='ENTERS';
elseif hasOut,      cls='EXITS';
end
end
