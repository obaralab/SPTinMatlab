function  CS_rho_plot(CSstruct,index,tWindow)

% Note: tWindow should be given in frames as [tmin tmax]

    %close all

    if nargin==2
        tWindow=[min(CSstruct(index).CSmatrix(:,:,1),[],"all","omitnan")  max(CSstruct(index).CSmatrix(:,:,1),[],"all","omitnan")+1];
    end

    %Things that might need updated occaisionally
    PixSize=30; %in nm
    ROI=[-20 20]; % +/- Dimensions analyzed in pixels (+/- 20 is 40 pix=1.2 um)
        % Change the last input if you want bigger regions (currently set to
        % 1.2 um neighborhoods for visualization (1.024 for analysis))
    
    % Make some dummy variables for linear indexing
    X=CSstruct(index).CSmatrix(:,:,2);
    Y=CSstruct(index).CSmatrix(:,:,3);
    T=CSstruct(index).CSmatrix(:,:,1);    
        
    % Find who is in the time window
    inTime=find(double(T>=tWindow(1)).*double(T<=tWindow(2))); 

    % Make the fig
    imG=LocDensityFigGenerate(X(inTime),Y(inTime),PixSize,ROI);
    
    % Save density plots
    fig1=figure;
    hold off
    imG=imresize(imG,10);
    imG=flip(imG,1);
    imshow(imG,turbo,'Border','tight');
    fig1.Position=[100 300 500 500];

    hold on
   % plot(CSstruct(index).refboundary(:,1)/3+200,CSstruct(index).refboundary(:,2)/3+200,'w','LineWidth',1.5);
    
   

end