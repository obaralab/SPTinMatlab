classdef ChrisPrograms
%CHRISPROGRAMS  Self-contained stand-in for the advisor's external TIFF-I/O
% helper class, so the ContactSites suite runs without that dependency.
%
% The suite calls only two static methods of ChrisPrograms — loadtiff and
% saveastiff. The advisor's originals are not distributed with the code, which
% is why runs fail with "Unable to resolve the name 'ChrisPrograms.saveastiff'".
% This drop-in implements both on base MATLAB (imread / imwrite) — no Image
% Processing Toolbox required.
%
% If you later obtain the advisor's original ChrisPrograms, delete this file so
% the original takes precedence on the path.
%
%   img = ChrisPrograms.loadtiff(fname)     % single page, RGB, or stack
%   ChrisPrograms.saveastiff(data, fname)   % 2-D, RGB (HxWx3), or stack (HxWxN)

    methods (Static)

        function img = loadtiff(fname)
            if exist(fname,'file') ~= 2
                error('ChrisPrograms:loadtiff:notFound','File not found: %s', fname);
            end
            info = imfinfo(fname);
            n = numel(info);
            if n == 1
                img = imread(fname);
                return;
            end
            a1 = imread(fname,1);
            if ndims(a1) == 3
                img = zeros([size(a1,1) size(a1,2) size(a1,3) n], class(a1));
                for k = 1:n, img(:,:,:,k) = imread(fname,k); end
            else
                img = zeros([size(a1,1) size(a1,2) n], class(a1));
                for k = 1:n, img(:,:,k) = imread(fname,k); end
            end
        end

        function saveastiff(data, fname, varargin)
            % A trailing legacy "options" struct (3rd arg) is accepted and ignored.
            % Treat HxWx3 as an RGB frame only for 8-bit data; a 3-plane non-uint8
            % array is almost always a 3-frame grayscale stack, not colour.
            isRGB = (ndims(data) == 3 && size(data,3) == 3 && isa(data,'uint8'));
            if ismatrix(data) || isRGB
                imwrite(data, fname);                         % one grayscale or RGB frame
            else
                imwrite(data(:,:,1), fname);                  % grayscale stack: write + append
                for k = 2:size(data,3)
                    imwrite(data(:,:,k), fname, 'WriteMode','append');
                end
            end
        end

    end
end
