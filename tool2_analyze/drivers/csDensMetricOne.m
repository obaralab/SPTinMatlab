function rec = csDensMetricOne(cs, cc, file, blank, binArea)
%CSDENSMETRICONE  One contact site's density metrics (Obara PMF + supplementary enrichment).
%
% Extracted VERBATIM from spt_pipeline_app.m (the paper-suite monolith) so the clean windowed
% pipeline can reuse it without depending on that file's private scope. Pure and self-contained
% (no shared/nested state). cc is that site's per-cell density cache; file is the cell name.
%
% CONTRACT (must be honoured by callers):
%   cs.refboundary : [K x 2] polygon in NANOMETRES relative to cs.refCenter (bx = refb/1000+rc).
%   cs.refCenter   : [x y] centre in um.   cs.csID, cs.cellIndex, cs.MitoFlag.
%   cc.rho, cc.Hc  : [xbin x ybin] smoothed density / raw counts (INDEXED rho(xbin,ybin) — i.e.
%                    the TRANSPOSE of a [row=y,col=x] image). cc.cxc/cc.cyc = x/y bin centres (um).
%   cc.rho_bg      : background density (occupied-bin mean of the SAME smoothed map).
%   cc.Xc/cc.Yc    : localization coords (um) for prob_mass. cc.cellTot = normalizing loc count.
%   binArea        : um^2 per bin.
rec = blank;
rec.csID = cs.csID; rec.cellIndex = cs.cellIndex; rec.mito = logical(cs.MitoFlag);
rec.file = file;
if isempty(cc) || isempty(cs.refboundary), return; end
rc = cs.refCenter;
bx = cs.refboundary(:,1)/1000+rc(1); by = cs.refboundary(:,2)/1000+rc(2);   % abs um
xmn=min(bx); xmx=max(bx); ymn=min(by); ymx=max(by);                         % site bounding box (um)
rec.area_um2 = polyarea(bx,by);
% bbox pre-filter keeps the exact inpolygon cheap (points outside the bbox are outside the polygon).
inbb = cc.Xc>=xmn & cc.Xc<=xmx & cc.Yc>=ymn & cc.Yc<=ymx;
rec.n_loc_in = nnz(inpolygon(cc.Xc(inbb),cc.Yc(inbb),bx,by));
rec.cell_total = cc.cellTot;
rec.prob_mass = rec.n_loc_in/max(cc.cellTot,1);
% smoothed-density bins whose CENTRES fall inside the boundary (bbox-limited)
ix = find(cc.cxc>=xmn&cc.cxc<=xmx); iy = find(cc.cyc>=ymn&cc.cyc<=ymx);
if ~isempty(ix)&&~isempty(iy)
    [GX,GY] = ndgrid(cc.cxc(ix),cc.cyc(iy)); sub = cc.rho(ix,iy); subR = cc.Hc(ix,iy);
    inG = inpolygon(GX(:),GY(:),bx,by); rhoIn = sub(inG); rawIn = subR(inG);
    if ~isempty(rhoIn)
        rec.peak_prob     = max(rhoIn)/max(cc.cellTot,1);   % smoothed-map peak (robust)
        rec.peak_prob_raw = max(rawIn)/max(cc.cellTot,1);   % strict raw-count PMF peak
        rec.local_dens    = mean(rhoIn)/binArea;            % loc/um^2
    end
end
if isfinite(cc.rho_bg), rec.cell_bg_dens = cc.rho_bg/binArea; end
if isfinite(rec.local_dens) && rec.cell_bg_dens>0
    rec.enrichment = rec.local_dens/rec.cell_bg_dens;       % dimensionless fold
end
end
