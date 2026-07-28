function ControlUpdated=refineCSboundary(Control,index)



A=Control(index).CSmatrix(:,:,2);
B=Control(index).CSmatrix(:,:,3);
C=Control(index).Deff;

       scatter(A(:),B(:),[],C(:),'filled');
       colormap(parula);
       fig1.Position=[300 300 768 768];
       xlim([-0.5 0.5])
       ylim([-0.5 0.5])
       hold on
       plot(Control(index).refboundary(:,1)/1000,Control(index).refboundary(:,2)/1000,'r');
       scatter(0,0,'k','filled');
       
       roi2=drawfreehand;
       hold off


Control(index).refboundary=[1000*(roi2.Position(:,1)) 1000*(roi2.Position(:,2))];

ControlUpdated=Control;


end