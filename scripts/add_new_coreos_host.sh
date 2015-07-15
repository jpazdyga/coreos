#!/bin/bash

updatehosts() {

        sed -n '/p/,/\[newcoreoshosts\]/p' $ansiblehosts > $tmpfilenamenew
        cat $tmpfilenameold >> $tmpfilenamenew
        echo $ipaddress >> $tmpfilenamenew
        cp $ansiblehosts $ansiblehosts.bkp
        cp $tmpfilenamenew $ansiblehosts
        rm -fr tmpfilenameold
        rm -fr tmpfilenamenew

}

proceed() {

        sed -n '/\[newcoreoshosts\]/,//p' $ansiblehosts | grep -v "\[" > $tmpfilenameold
        alreadythere=`grep $ipaddress $tmpfilenameold`
        if [ -z "$alreadythere" ];
        then   
                updatehosts
        else   
                exit 1
        fi

}

conncheck() {

        result=`ping -q -c5 -i .5 $ipaddress 2>&1 > /dev/null; echo $?`
        if [ "$result" -eq "0" ];
        then
                proceed
        else
                echo "Waiting for host to appear..."
                sleep 10
                conncheck
        fi

}

ipaddress="$1"
ansiblehosts="/etc/ansible/hosts"
tmpfilenameold="$HOME/tmp/newcoreoshost.old"
tmpfilenamenew="$HOME/tmp/newcoreoshost.new"

conncheck
