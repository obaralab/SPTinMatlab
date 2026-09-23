function s = cs_read_sites(txt)
%CS_READ_SITES  Parse a picker <base>_CSsites.txt into per-site arrays.
%   s = cs_read_sites(txt) -> struct with fields Xpx, Ypx (density px), w (window/Slice), mito.
% Columns: [idx X Y XM YM Slice Counter Count]. Uses refined XM/YM (cols 4/5) when present, else
% X/Y (2/3). Counter (col 7): 1 -> mito, 2 -> non-mito; a 6-col file => all non-mito.
D = importdata(txt);
if isstruct(D) && isfield(D,'data'), M = D.data; else, M = D; end
if isempty(M), s = struct('Xpx',[],'Ypx',[],'w',[],'mito',[]); return; end
nc = size(M,2);
if nc>=5, Xpx = M(:,4); Ypx = M(:,5); else, Xpx = M(:,2); Ypx = M(:,3); end
if nc>=6, w = round(M(:,6)); else, w = ones(size(Xpx)); end
if nc>=7, mito = (round(M(:,7))==1); else, mito = false(size(Xpx)); end
w(~isfinite(w) | w<1) = 1;
s = struct('Xpx',Xpx,'Ypx',Ypx,'w',w,'mito',mito);
end
