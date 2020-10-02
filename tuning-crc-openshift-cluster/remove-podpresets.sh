OC=${OC:-oc}

for i in {1..60}
do
	namespace=`oc get ns |  awk 'NR=="'"$i"'"{print $1}'`
	if [[ "$namespace" =~ "openshift-" ]]; then
			echo 'Removing podpreset for the namespace: "'"$namespace"'"' 
			${OC} delete podpreset/crc-performance-turning -n $namespace
	fi
done
