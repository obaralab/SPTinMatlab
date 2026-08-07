function tf = cs_sites_near(CS, key)
%CS_SITES_NEAR  Vectorised cs_site_near over a CS array — logical row, one entry per site.
%
%   tf = cs_sites_near(CS, key)
%
% Replaces the bulk idiom logical([CS.MitoFlag]). Not just a rename: [CS.MitoFlag] concatenates, so
% one site whose flag is [] SHORTENS the result and silently misaligns every index derived from it.
% This always returns numel(CS) entries, with a missing or empty flag reading FALSE.
tf = false(1, numel(CS));
for k = 1:numel(CS), tf(k) = cs_site_near(CS(k), key); end
end
