
function fig1=CS_interactiveFig(CSstruct,index)

    fig1=figure(1);
    X=CSstruct(index).CSmatrix(:,:,2);
    Y=CSstruct(index).CSmatrix(:,:,3);

    scatter(X(:),Y(:),[],CSstruct(index).Deff(:),'filled');
    axis square
    colormap viridis
    colorbar
    hold on
    scatter(X(CSstruct(index).CSLocIDs),Y(CSstruct(index).CSLocIDs),'r');
    scatter(X(CSstruct(index).CSneighborIDs),Y(CSstruct(index).CSneighborIDs),'b');
    %plot(X,Y);

end