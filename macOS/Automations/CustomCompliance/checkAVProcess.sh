#!/bin/bash
PROCESS=AVProcessName
number=$(ps aux | grep -ci $PROCESS)

if [ $number -gt 0 ]
    then
        echo Running;
fi