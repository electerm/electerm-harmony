const pkg = require('shelljs')

const { echo, rm, cp } = pkg

echo('install required modules')

rm('-rf', 'src/client')
cp('-r', 'node_modules/@electerm/electerm-react/client', 'src/client')
echo('done install required modules')
