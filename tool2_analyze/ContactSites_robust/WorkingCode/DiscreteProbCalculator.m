
function A=DiscreteProbCalculator(X,Y,Var,center)

%THIS IS NOT WORKING PROPERLY, YET.

if nargin==3
    center=[0 0];
end

    x=center(1);
    y=center(2);
    radial_length=1; %in microns
    
% Derfine Step Size and Integration Bounds
    d_theta = 1;
    n_theta = 360/d_theta;
    
% Preallocate the memory to hold the data
    radial_plot = zeros(n_theta,100*radial_length,2);
    
for k=91:180%n_theta
    
     theta=k*d_theta;
     xi = [x x+(radial_length)*cosd(theta)];
     yi = [y y+(radial_length)*sind(theta)];
     Endpts=[xi;yi];
     
     [Deff,rho,~,~]=LinePlotScatterAvg(X,Y,Var,Endpts);
     
     radial_plot(k,:,1)=Deff(1:100)';
     radial_plot(k,:,2)=rho(1:100)';  
    
end

A=radial_plot;